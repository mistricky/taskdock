"""Report message hints available from desktop notifications and messaging tray icons."""

import json
import sys
import time


def app_for_notification(name):
    normalized = str(name or "").strip().lower().replace(" ", "")
    if normalized in {"wechat", "weixin", "微信", "wechatlinux_x86_64"}:
        return "wechat"
    return ""


def has_feishu_badge(images):
    for width, height, data in images:
        width, height = int(width), int(height)
        pixels = bytes(data)
        if width <= 0 or height <= 0 or len(pixels) != width * height * 4:
            continue
        red = 0
        for y in range(max(1, int(height * 0.45))):
            for x in range(int(width * 0.55), width):
                offset = 4 * (y * width + x)
                alpha, r, g, b = pixels[offset:offset + 4]
                if alpha > 100 and r > 150 and r > g * 1.5 and r > b * 1.5:
                    red += 1
        if red >= 4:
            return True
    return False


def is_blank_wechat_icon(images):
    if not images:
        return False
    for width, height, data in images:
        width, height = int(width), int(height)
        pixels = bytes(data)
        if width <= 0 or height <= 0 or len(pixels) != width * height * 4:
            return False
        if any(pixels[offset] for offset in range(0, len(pixels), 4)):
            return False
    return True


def emit(**event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


def main():
    import dbus
    import dbus.mainloop.glib
    from gi.repository import GLib

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus(private=True)
    state = {"services": {}, "signal_matches": [],
             "wechat_unread": False, "wechat_last_blank": 0.0}

    def refresh_feishu():
        service = state["services"].get("feishu")
        if not service:
            emit(kind="feishu", present=False, unread=False)
            return
        try:
            item = bus.get_object(service, "/StatusNotifierItem")
            props = dbus.Interface(item, "org.freedesktop.DBus.Properties")
            images = props.Get("org.kde.StatusNotifierItem", "IconPixmap")
            emit(kind="feishu", present=True, unread=has_feishu_badge(images))
        except dbus.DBusException:
            emit(kind="feishu", present=False, unread=False)

    def set_wechat_unread(unread):
        if state["wechat_unread"] != unread:
            state["wechat_unread"] = unread
            emit(kind="wechat", unread=unread)

    def refresh_wechat():
        service = state["services"].get("wechat")
        if not service:
            state["wechat_last_blank"] = 0.0
            set_wechat_unread(False)
            return
        try:
            item = bus.get_object(service, "/StatusNotifierItem")
            props = dbus.Interface(item, "org.freedesktop.DBus.Properties")
            images = props.Get("org.kde.StatusNotifierItem", "IconPixmap")
            if is_blank_wechat_icon(images):
                state["wechat_last_blank"] = time.monotonic()
                set_wechat_unread(True)
        except dbus.DBusException:
            pass

    def expire_wechat():
        if state["wechat_unread"] and time.monotonic() - state["wechat_last_blank"] > 2.5:
            set_wechat_unread(False)
        return True

    def find_items():
        for match in state["signal_matches"]:
            match.remove()
        state["signal_matches"] = []
        state["services"] = {}
        for name in bus.list_names():
            if not name.startswith("org.kde.StatusNotifierItem-"):
                continue
            try:
                item = bus.get_object(name, "/StatusNotifierItem")
                props = dbus.Interface(item, "org.freedesktop.DBus.Properties")
                item_id = str(props.Get("org.kde.StatusNotifierItem", "Id"))
                kind = {"lark_status_icon_1": "feishu", "wechat": "wechat"}.get(item_id)
                if not kind:
                    continue
                state["services"][kind] = name
                refresh = refresh_feishu if kind == "feishu" else refresh_wechat
                for signal in ("NewIcon", "NewOverlayIcon"):
                    state["signal_matches"].append(bus.add_signal_receiver(
                        lambda *args, callback=refresh: callback(), signal_name=signal,
                        dbus_interface="org.kde.StatusNotifierItem", bus_name=name,
                        path="/StatusNotifierItem"))
                state["signal_matches"].append(bus.add_signal_receiver(
                    lambda *args, callback=refresh: callback(), signal_name="PropertiesChanged",
                    dbus_interface="org.freedesktop.DBus.Properties", bus_name=name,
                    path="/StatusNotifierItem"))
            except dbus.DBusException:
                continue
        refresh_feishu()
        refresh_wechat()

    def on_name_change(name, old_owner, new_owner):
        if str(name).startswith("org.kde.StatusNotifierItem-"):
            find_items()

    bus.add_signal_receiver(on_name_change, signal_name="NameOwnerChanged",
                            dbus_interface="org.freedesktop.DBus", path="/org/freedesktop/DBus")
    find_items()
    GLib.timeout_add(500, expire_wechat)

    monitor = dbus.SessionBus(private=True)

    def on_message(connection, message):
        if message.get_interface() != "org.freedesktop.Notifications" or message.get_member() != "Notify":
            return
        args = message.get_args_list()
        if not args:
            return
        app = app_for_notification(args[0])
        if not app and len(args) > 6:
            app = app_for_notification(args[6].get("desktop-entry", ""))
        if app:
            emit(kind="notification", app=app)

    monitor.add_message_filter(on_message)
    monitor.call_blocking(
        "org.freedesktop.DBus", "/org/freedesktop/DBus",
        "org.freedesktop.DBus.Monitoring", "BecomeMonitor", "asu",
        (["type='method_call',interface='org.freedesktop.Notifications',member='Notify'"], 0),
    )
    GLib.MainLoop().run()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"notification watcher failed: {error}", file=sys.stderr, flush=True)
        raise
