/* eclaw service worker — Web Push notifications for the chat UI */

self.addEventListener("push", (event) => {
  let payload = { title: "eclaw", body: "", url: "./" };
  if (event.data) {
    try {
      payload = { ...payload, ...event.data.json() };
    } catch (_err) {
      payload.body = event.data.text();
    }
  }
  const title = payload.title || "eclaw";
  const options = {
    body: payload.body || "",
    data: { url: payload.url || "./" },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "./";
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const client of list) {
        try {
          const clientUrl = new URL(client.url);
          const targetUrl = new URL(target, clientUrl.origin);
          if (clientUrl.pathname === targetUrl.pathname && "focus" in client) {
            return client.focus();
          }
        } catch (_err) {
          /* ignore malformed URLs */
        }
      }
      if (clients.openWindow) {
        return clients.openWindow(target);
      }
      return undefined;
    })
  );
});
