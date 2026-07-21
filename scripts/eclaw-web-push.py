#!/usr/bin/env python3
"""Send Web Push notifications for eclaw via pywebpush."""

from __future__ import annotations

import argparse
import copy
import json
import sys
from urllib.parse import urlparse


def load_json(path: str):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def audience_for_endpoint(endpoint: str) -> str:
    parsed = urlparse(endpoint)
    return f"{parsed.scheme}://{parsed.netloc}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Send eclaw Web Push notifications")
    parser.add_argument("--vapid-file", required=True)
    parser.add_argument("--subscriptions-file", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--body", required=True)
    parser.add_argument("--url", default="")
    args = parser.parse_args()

    try:
        from pywebpush import WebPushException, webpush
    except ImportError:
        print("pywebpush is not installed", file=sys.stderr)
        return 2

    vapid = load_json(args.vapid_file)
    private_key = vapid.get("privateKey") or vapid.get("private_key")
    subject = vapid.get("subject") or vapid.get("sub") or "mailto:eclaw@localhost"
    if not private_key:
        print("missing privateKey in vapid file", file=sys.stderr)
        return 1

    subscriptions = load_json(args.subscriptions_file)
    if not isinstance(subscriptions, list) or not subscriptions:
        return 0

    payload = json.dumps(
        {"title": args.title, "body": args.body, "url": args.url},
        ensure_ascii=False,
    )
    base_claims = {"sub": subject}
    stale_endpoints: list[str] = []
    errors = 0

    for subscription in subscriptions:
        if not isinstance(subscription, dict):
            continue
        endpoint = subscription.get("endpoint")
        if not endpoint:
            continue
        claims = copy.copy(base_claims)
        claims["aud"] = audience_for_endpoint(endpoint)
        try:
            webpush(
                subscription_info=subscription,
                data=payload,
                vapid_private_key=private_key,
                vapid_claims=claims,
            )
        except WebPushException as exc:
            status = None
            if exc.response is not None:
                status = getattr(exc.response, "status_code", None)
            if status in (404, 410):
                stale_endpoints.append(endpoint)
            else:
                print(f"push failed for {endpoint}: {exc!r}", file=sys.stderr)
                errors += 1

    if stale_endpoints:
        remaining = [
            sub
            for sub in subscriptions
            if sub.get("endpoint") not in stale_endpoints
        ]
        with open(args.subscriptions_file, "w", encoding="utf-8") as handle:
            json.dump(remaining, handle, indent=2)
            handle.write("\n")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
