"""Check notification attribution and messaging tray icon signals."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from notification_watch import app_for_notification, has_feishu_badge, is_blank_wechat_icon


class NotificationWatchTests(unittest.TestCase):
    def test_only_wechat_notification_names_are_attributed(self):
        for name in ("WeChat", "Weixin", "微信", "WeChatLinux_x86_64"):
            self.assertEqual(app_for_notification(name), "wechat")
        self.assertEqual(app_for_notification("Kitty"), "")

    def test_badge_requires_red_pixels_in_top_right_corner(self):
        pixels = bytearray(36 * 36 * 4)
        for x in range(28, 33):
            pixels[4 * (4 * 36 + x):4 * (4 * 36 + x) + 4] = bytes((255, 245, 40, 40))
        self.assertTrue(has_feishu_badge([(36, 36, pixels)]))

        pixels = bytearray(36 * 36 * 4)
        for x in range(3, 8):
            pixels[4 * (30 * 36 + x):4 * (30 * 36 + x) + 4] = bytes((255, 245, 40, 40))
        self.assertFalse(has_feishu_badge([(36, 36, pixels)]))

    def test_wechat_unread_blink_uses_transparent_tray_frame(self):
        blank = bytearray(16 * 16 * 4)
        self.assertTrue(is_blank_wechat_icon([(16, 16, blank)]))
        blank[0] = 255
        self.assertFalse(is_blank_wechat_icon([(16, 16, blank)]))
        self.assertFalse(is_blank_wechat_icon([]))


if __name__ == "__main__":
    unittest.main()
