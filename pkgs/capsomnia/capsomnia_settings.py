#!/usr/bin/env python3
"""GTK4 Settings and Welcome Guide window for Capsomnia."""

from __future__ import annotations

import sys
from typing import Any

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

from capsomnia_core import (  # noqa: E402
    AUTO_OFF_PRESETS,
    MAX_CUSTOM_MINUTES,
    VERSION,
    format_compact_duration,
    format_countdown,
    resolve_language,
    tr,
)
from cpsm import send_control  # noqa: E402

APP_CSS = """
window {
  background-color: #0b0f14;
  color: #e6edf3;
}
.card {
  background-color: #111822;
  border: 1px solid #1e2a38;
  border-radius: 10px;
  padding: 14px;
}
.led-dot {
  min-width: 18px;
  min-height: 18px;
  border-radius: 999px;
}
.led-on {
  background-color: #34c759;
  box-shadow: 0 0 12px #34c759;
}
.led-off {
  background-color: #55606e;
}
.led-err {
  background-color: #e06c75;
  box-shadow: 0 0 10px #e06c75;
}
.title-lbl {
  font-size: 18px;
  font-weight: 700;
  color: #e6edf3;
}
.sub-lbl {
  font-size: 12px;
  color: #9aa7b5;
}
.sec-lbl {
  font-size: 12px;
  font-weight: 700;
  color: #33c5c5;
}
.mono-big {
  font-family: monospace;
  font-size: 18px;
  font-weight: 700;
  color: #9fe7e7;
}
.badge {
  background-color: #15383a;
  color: #9fe7e7;
  border-radius: 6px;
  padding: 2px 8px;
  font-size: 11px;
}
button.chip {
  padding: 4px 10px;
  border-radius: 6px;
  background-color: #182230;
  color: #e6edf3;
  border: 1px solid #283648;
}
button.chip-active {
  background-color: #15383a;
  color: #9fe7e7;
  border: 1px solid #33c5c5;
}
button.primary-btn {
  background-color: #15383a;
  color: #e6edf3;
  border: 1px solid #33c5c5;
  border-radius: 8px;
  padding: 6px 14px;
  font-weight: 600;
}
"""


class CapsomniaWindow(Gtk.ApplicationWindow):
    def __init__(self, app: Gtk.Application, *, welcome_only: bool = False) -> None:
        super().__init__(application=app, title="Capsomnia")
        self.set_default_size(520, 620)
        self._updating_ui = False
        self._welcome_mode = welcome_only
        self._last_lang = "ja"
        self._timer_buttons: dict[int, Gtk.Button] = {}

        display = Gdk.Display.get_default()
        if display is not None:
            provider = Gtk.CssProvider()
            provider.load_from_data(APP_CSS.encode("utf-8"))
            Gtk.StyleContext.add_provider_for_display(
                display, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )

        self.root_stack = Gtk.Stack()
        self.root_stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        self.set_child(self.root_stack)

        self._build_settings_view()
        self._build_welcome_view()

        if welcome_only:
            self.root_stack.set_visible_child_name("welcome")
        else:
            self.root_stack.set_visible_child_name("settings")

        self.refresh_state()
        GLib.timeout_add(1000, self._on_tick)

    def _on_tick(self) -> bool:
        self.refresh_state()
        return True

    def _build_welcome_view(self) -> None:
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        box.set_margin_top(24)
        box.set_margin_bottom(24)
        box.set_margin_start(24)
        box.set_margin_end(24)

        head = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        dot = Gtk.Box()
        dot.add_css_class("led-dot")
        dot.add_css_class("led-on")
        dot.set_valign(Gtk.Align.CENTER)
        self.w_title = Gtk.Label(xalign=0)
        self.w_title.add_css_class("title-lbl")
        head.append(dot)
        head.append(self.w_title)
        box.append(head)

        self.w_body = Gtk.Label(xalign=0, wrap=True)
        self.w_body.add_css_class("sub-lbl")
        box.append(self.w_body)

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        card.add_css_class("card")

        self.w_sw_menubar = Gtk.Switch()
        self.w_sw_menubar.set_valign(Gtk.Align.CENTER)
        self.w_sw_menubar.connect("notify::active", self._on_welcome_menubar)
        self.w_lbl_menubar = Gtk.Label(xalign=0, hexpand=True)
        row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        row1.append(self.w_lbl_menubar)
        row1.append(self.w_sw_menubar)
        card.append(row1)

        self.w_sw_ded = Gtk.Switch()
        self.w_sw_ded.set_valign(Gtk.Align.CENTER)
        self.w_sw_ded.connect("notify::active", self._on_welcome_dedicated)
        self.w_lbl_ded = Gtk.Label(xalign=0, hexpand=True)
        row2 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        row2.append(self.w_lbl_ded)
        row2.append(self.w_sw_ded)
        card.append(row2)

        self.w_lang_combo = Gtk.DropDown.new_from_strings(["Auto", "日本語", "English"])
        self.w_lang_combo.connect("notify::selected", self._on_lang_changed)
        self.w_lbl_lang = Gtk.Label(xalign=0, hexpand=True)
        row3 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        row3.append(self.w_lbl_lang)
        row3.append(self.w_lang_combo)
        card.append(row3)

        box.append(card)

        spacer = Gtk.Box(vexpand=True)
        box.append(spacer)

        self.w_btn_start = Gtk.Button()
        self.w_btn_start.add_css_class("primary-btn")
        self.w_btn_start.connect("clicked", self._on_welcome_finish)
        box.append(self.w_btn_start)

        self.root_stack.add_named(box, "welcome")

    def _build_settings_view(self) -> None:
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        box.set_margin_top(18)
        box.set_margin_bottom(18)
        box.set_margin_start(18)
        box.set_margin_end(18)
        scroll.set_child(box)

        # Header card
        hdr = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        hdr.add_css_class("card")
        self.led_dot = Gtk.Box()
        self.led_dot.add_css_class("led-dot")
        self.led_dot.add_css_class("led-off")
        self.led_dot.set_valign(Gtk.Align.CENTER)
        hdr.append(self.led_dot)

        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        top_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.lbl_title = Gtk.Label(label="Capsomnia", xalign=0)
        self.lbl_title.add_css_class("title-lbl")
        self.lbl_lid_badge = Gtk.Label(label="")
        self.lbl_lid_badge.add_css_class("badge")
        top_row.append(self.lbl_title)
        top_row.append(self.lbl_lid_badge)
        titles.append(top_row)
        self.lbl_subtitle = Gtk.Label(xalign=0, wrap=True)
        self.lbl_subtitle.add_css_class("sub-lbl")
        titles.append(self.lbl_subtitle)
        hdr.append(titles)

        self.btn_power = Gtk.Button()
        self.btn_power.add_css_class("primary-btn")
        self.btn_power.set_valign(Gtk.Align.CENTER)
        self.btn_power.connect("clicked", self._on_toggle_power)
        hdr.append(self.btn_power)
        box.append(hdr)

        # Day-to-day card
        daily = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        daily.add_css_class("card")
        self.lbl_sec_daily = Gtk.Label(xalign=0)
        self.lbl_sec_daily.add_css_class("sec-lbl")
        daily.append(self.lbl_sec_daily)

        # Keep display awake
        disp_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        disp_txt = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        self.lbl_keep_disp = Gtk.Label(xalign=0, wrap=True)
        self.lbl_keep_disp_desc = Gtk.Label(xalign=0, wrap=True)
        self.lbl_keep_disp_desc.add_css_class("sub-lbl")
        disp_txt.append(self.lbl_keep_disp)
        disp_txt.append(self.lbl_keep_disp_desc)
        self.sw_keep_disp = Gtk.Switch()
        self.sw_keep_disp.set_valign(Gtk.Align.CENTER)
        self.sw_keep_disp.connect("notify::active", self._on_keep_disp_toggled)
        disp_row.append(disp_txt)
        disp_row.append(self.sw_keep_disp)
        daily.append(disp_row)

        # Lock on lid open (sub-option under keep display awake)
        self.lock_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.lock_box.set_margin_start(16)
        self.chk_lock_open = Gtk.CheckButton()
        self.chk_lock_open.connect("toggled", self._on_lock_open_toggled)
        lock_txt = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        self.lbl_lock_open = Gtk.Label(xalign=0, wrap=True)
        self.lbl_lock_open_desc = Gtk.Label(xalign=0, wrap=True)
        self.lbl_lock_open_desc.add_css_class("sub-lbl")
        lock_txt.append(self.lbl_lock_open)
        lock_txt.append(self.lbl_lock_open_desc)
        self.lock_box.append(self.chk_lock_open)
        self.lock_box.append(lock_txt)
        daily.append(self.lock_box)

        daily.append(Gtk.Separator())

        # Auto-off timer
        tm_hdr = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        tm_txt = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        self.lbl_timer = Gtk.Label(xalign=0)
        self.lbl_timer_desc = Gtk.Label(xalign=0, wrap=True)
        self.lbl_timer_desc.add_css_class("sub-lbl")
        tm_txt.append(self.lbl_timer)
        tm_txt.append(self.lbl_timer_desc)
        self.lbl_countdown = Gtk.Label(label="∞")
        self.lbl_countdown.add_css_class("mono-big")
        self.btn_restart_timer = Gtk.Button()
        self.btn_restart_timer.add_css_class("chip")
        self.btn_restart_timer.connect("clicked", self._on_restart_timer)
        tm_hdr.append(tm_txt)
        tm_hdr.append(self.lbl_countdown)
        tm_hdr.append(self.btn_restart_timer)
        daily.append(tm_hdr)

        chips = Gtk.FlowBox()
        chips.set_selection_mode(Gtk.SelectionMode.NONE)
        chips.set_max_children_per_line(4)
        chips.set_row_spacing(6)
        chips.set_column_spacing(6)
        for mins in (0, *AUTO_OFF_PRESETS):
            btn = Gtk.Button(label=format_compact_duration(mins))
            btn.add_css_class("chip")
            btn.connect("clicked", self._on_preset_clicked, mins)
            self._timer_buttons[mins] = btn
            chips.append(btn)
        daily.append(chips)

        custom_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.lbl_custom = Gtk.Label(xalign=0)
        self.lbl_custom.add_css_class("sub-lbl")
        self.spin_hours = Gtk.SpinButton.new_with_range(0, 24, 1)
        self.lbl_h = Gtk.Label(label="h")
        self.spin_mins = Gtk.SpinButton.new_with_range(0, 59, 5)
        self.lbl_m = Gtk.Label(label="m")
        self.btn_custom_apply = Gtk.Button()
        self.btn_custom_apply.add_css_class("chip")
        self.btn_custom_apply.connect("clicked", self._on_custom_apply)
        custom_row.append(self.lbl_custom)
        custom_row.append(self.spin_hours)
        custom_row.append(self.lbl_h)
        custom_row.append(self.spin_mins)
        custom_row.append(self.lbl_m)
        custom_row.append(self.btn_custom_apply)
        daily.append(custom_row)

        box.append(daily)

        # Advanced Settings Expander
        self.expander = Gtk.Expander()
        adv_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        adv_card.add_css_class("card")
        adv_card.set_margin_top(6)

        # Show Waybar dot
        r_mb = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.lbl_menubar = Gtk.Label(xalign=0, hexpand=True)
        self.sw_menubar = Gtk.Switch()
        self.sw_menubar.connect("notify::active", self._on_switch_setting, "show-menu-bar-icon")
        r_mb.append(self.lbl_menubar)
        r_mb.append(self.sw_menubar)
        adv_card.append(r_mb)

        # Prevent all-caps
        r_ded = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        ded_txt = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        self.lbl_ded = Gtk.Label(xalign=0)
        self.lbl_ded_desc = Gtk.Label(xalign=0, wrap=True)
        self.lbl_ded_desc.add_css_class("sub-lbl")
        ded_txt.append(self.lbl_ded)
        ded_txt.append(self.lbl_ded_desc)
        self.sw_ded = Gtk.Switch()
        self.sw_ded.set_valign(Gtk.Align.CENTER)
        self.sw_ded.connect("notify::active", self._on_switch_setting, "dedicated-caps-lock-mode")
        r_ded.append(ded_txt)
        r_ded.append(self.sw_ded)
        adv_card.append(r_ded)

        # Shortcut
        r_sc = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.lbl_shortcut = Gtk.Label(xalign=0, hexpand=True)
        self.entry_shortcut = Gtk.Entry()
        self.entry_shortcut.set_width_chars(16)
        self.btn_shortcut = Gtk.Button(label="Set")
        self.btn_shortcut.add_css_class("chip")
        self.btn_shortcut.connect("clicked", self._on_shortcut_apply)
        r_sc.append(self.lbl_shortcut)
        r_sc.append(self.entry_shortcut)
        r_sc.append(self.btn_shortcut)
        adv_card.append(r_sc)

        # Ignore external off while lid closed
        r_ext = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.lbl_ext_off = Gtk.Label(xalign=0, hexpand=True, wrap=True)
        self.sw_ext_off = Gtk.Switch()
        self.sw_ext_off.connect(
            "notify::active", self._on_switch_setting, "ignore-external-caps-lock-off-while-lid-closed"
        )
        r_ext.append(self.lbl_ext_off)
        r_ext.append(self.sw_ext_off)
        adv_card.append(r_ext)

        # Keep hotspot connected
        r_hs = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        hs_txt = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, hexpand=True)
        self.lbl_hotspot = Gtk.Label(xalign=0)
        self.lbl_hotspot_desc = Gtk.Label(xalign=0, wrap=True)
        self.lbl_hotspot_desc.add_css_class("sub-lbl")
        hs_txt.append(self.lbl_hotspot)
        hs_txt.append(self.lbl_hotspot_desc)
        self.sw_hotspot = Gtk.Switch()
        self.sw_hotspot.set_valign(Gtk.Align.CENTER)
        self.sw_hotspot.connect("notify::active", self._on_switch_setting, "keep-hotspot-alive")
        r_hs.append(hs_txt)
        r_hs.append(self.sw_hotspot)
        adv_card.append(r_hs)

        # Language
        r_lang = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.lbl_lang = Gtk.Label(xalign=0, hexpand=True)
        self.lang_combo = Gtk.DropDown.new_from_strings(["Auto", "日本語", "English"])
        self.lang_combo.connect("notify::selected", self._on_lang_changed)
        r_lang.append(self.lbl_lang)
        r_lang.append(self.lang_combo)
        adv_card.append(r_lang)

        # Welcome button + version
        r_foot = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.btn_welcome = Gtk.Button()
        self.btn_welcome.add_css_class("chip")
        self.btn_welcome.connect("clicked", lambda _b: self.root_stack.set_visible_child_name("welcome"))
        self.lbl_ver = Gtk.Label(label=f"v{VERSION}", xalign=1, hexpand=True)
        self.lbl_ver.add_css_class("sub-lbl")
        r_foot.append(self.btn_welcome)
        r_foot.append(self.lbl_ver)
        adv_card.append(r_foot)

        self.expander.set_child(adv_card)
        box.append(self.expander)

        self.root_stack.add_named(scroll, "settings")

    def _apply_language(self, lang_pref: str) -> None:
        lang = resolve_language(lang_pref)
        self._last_lang = lang
        self.lbl_sec_daily.set_text(tr(lang, "sec_daily"))
        self.lbl_keep_disp.set_text(tr(lang, "keep_display_awake"))
        self.lbl_keep_disp_desc.set_text(tr(lang, "keep_display_awake_desc"))
        self.lbl_lock_open.set_text(tr(lang, "lock_on_lid_open"))
        self.lbl_lock_open_desc.set_text(tr(lang, "lock_on_lid_open_desc"))
        self.lbl_timer.set_text(tr(lang, "auto_off_timer"))
        self.lbl_timer_desc.set_text(tr(lang, "auto_off_timer_desc"))
        self.btn_restart_timer.set_label(tr(lang, "timer_restart"))
        self.lbl_custom.set_text(tr(lang, "timer_custom") + ":")
        self.btn_custom_apply.set_label(tr(lang, "custom_apply"))
        self.expander.set_label(tr(lang, "sec_advanced"))
        self.lbl_menubar.set_text(tr(lang, "show_menubar"))
        self.lbl_ded.set_text(tr(lang, "prevent_all_caps"))
        self.lbl_ded_desc.set_text(tr(lang, "prevent_all_caps_desc"))
        self.lbl_shortcut.set_text(tr(lang, "shortcut_label"))
        self.lbl_ext_off.set_text(tr(lang, "ignore_external_off"))
        self.lbl_hotspot.set_text(tr(lang, "keep_hotspot"))
        self.lbl_hotspot_desc.set_text(tr(lang, "keep_hotspot_desc"))
        self.lbl_lang.set_text(tr(lang, "language"))
        self.btn_welcome.set_label(tr(lang, "show_welcome"))
        self.w_title.set_text(tr(lang, "welcome_title"))
        self.w_body.set_text(tr(lang, "welcome_body"))
        self.w_lbl_menubar.set_text(tr(lang, "show_menubar"))
        self.w_lbl_ded.set_text(tr(lang, "prevent_all_caps"))
        self.w_lbl_lang.set_text(tr(lang, "language"))
        self.w_btn_start.set_label(tr(lang, "welcome_start"))

    def refresh_state(self) -> None:
        resp = send_control(["status"])
        if not resp.get("ok"):
            return
        st: dict[str, Any] = resp["result"]
        settings = st["settings"]
        lang_pref = settings.get("language", "auto")
        lang = resolve_language(lang_pref)

        self._updating_ui = True
        try:
            self._apply_language(lang_pref)

            # LED indicator
            for cls in ("led-on", "led-off", "led-err"):
                self.led_dot.remove_css_class(cls)
            if st.get("status_error"):
                self.led_dot.add_css_class("led-err")
                err_msg = st.get("error_message")
                err_txt = tr(lang, "subtitle_err")
                if err_msg:
                    err_txt = f"{err_txt} ({err_msg})"
                self.lbl_subtitle.set_text(err_txt)
            elif st.get("awake_on"):
                self.led_dot.add_css_class("led-on")
                self.lbl_subtitle.set_text(tr(lang, "subtitle_on"))
            else:
                self.led_dot.add_css_class("led-off")
                self.lbl_subtitle.set_text(tr(lang, "subtitle_off"))

            self.btn_power.set_label(tr(lang, "btn_turn_off" if st.get("awake_on") else "btn_turn_on"))

            lid = st.get("lid_closed")
            self.lbl_lid_badge.set_text(
                tr(lang, "lid_closed" if lid is True else ("lid_open" if lid is False else "lid_unknown"))
            )

            keep_disp = bool(settings.get("keep_display_awake"))
            self.sw_keep_disp.set_active(keep_disp)
            self.lock_box.set_visible(keep_disp)
            self.chk_lock_open.set_active(bool(settings.get("lock_on_lid_open")))

            timer = st.get("timer", {})
            saved_mins = int(settings.get("auto_off_minutes", 0))
            if st.get("awake_on") and timer.get("active") and timer.get("remaining_seconds") is not None:
                self.lbl_countdown.set_text(format_countdown(timer["remaining_seconds"]))
                self.btn_restart_timer.set_sensitive(True)
            else:
                self.lbl_countdown.set_text(format_compact_duration(saved_mins))
                self.btn_restart_timer.set_sensitive(False)

            for mins, btn in self._timer_buttons.items():
                if mins == saved_mins:
                    btn.add_css_class("chip-active")
                else:
                    btn.remove_css_class("chip-active")

            self.sw_menubar.set_active(bool(settings.get("show_menu_bar_icon")))
            self.w_sw_menubar.set_active(bool(settings.get("show_menu_bar_icon")))
            self.sw_ded.set_active(bool(settings.get("dedicated_caps_lock_mode")))
            self.w_sw_ded.set_active(bool(settings.get("dedicated_caps_lock_mode")))
            self.sw_ext_off.set_active(
                bool(settings.get("ignore_external_caps_lock_off_while_lid_closed"))
            )
            self.sw_hotspot.set_active(bool(settings.get("keep_hotspot_alive")))

            if not self.entry_shortcut.has_focus():
                self.entry_shortcut.set_text(str(settings.get("shortcut") or ""))

            idx = {"auto": 0, "ja": 1, "en": 2}.get(lang_pref, 0)
            self.lang_combo.set_selected(idx)
            self.w_lang_combo.set_selected(idx)
        finally:
            self._updating_ui = False

    def _on_toggle_power(self, _btn: Gtk.Button) -> None:
        send_control(["toggle", "--no-sleep"])
        self.refresh_state()

    def _on_keep_disp_toggled(self, sw: Gtk.Switch, _pspec: Any) -> None:
        if self._updating_ui:
            return
        send_control(["settings", "set", "keep-display-awake", "true" if sw.get_active() else "false"])
        self.refresh_state()

    def _on_lock_open_toggled(self, chk: Gtk.CheckButton) -> None:
        if self._updating_ui:
            return
        send_control(["settings", "set", "lock-on-lid-open", "true" if chk.get_active() else "false"])
        self.refresh_state()

    def _on_preset_clicked(self, _btn: Gtk.Button, mins: int) -> None:
        send_control(["settings", "set", "auto-off-minutes", str(mins)])
        self.refresh_state()

    def _on_custom_apply(self, _btn: Gtk.Button) -> None:
        h = int(self.spin_hours.get_value())
        m = int(self.spin_mins.get_value())
        total = min(max(h * 60 + m, 1), MAX_CUSTOM_MINUTES)
        send_control(["settings", "set", "auto-off-minutes", str(total)])
        self.refresh_state()

    def _on_restart_timer(self, _btn: Gtk.Button) -> None:
        send_control(["timer", "restart"])
        self.refresh_state()

    def _on_switch_setting(self, sw: Gtk.Switch, _pspec: Any, key: str) -> None:
        if self._updating_ui:
            return
        send_control(["settings", "set", key, "true" if sw.get_active() else "false"])
        self.refresh_state()

    def _on_shortcut_apply(self, _btn: Gtk.Button) -> None:
        val = self.entry_shortcut.get_text().strip()
        send_control(["settings", "set", "shortcut", val])
        self.refresh_state()

    def _on_lang_changed(self, combo: Gtk.DropDown, _pspec: Any) -> None:
        if self._updating_ui:
            return
        idx = combo.get_selected()
        val = {0: "auto", 1: "ja", 2: "en"}.get(idx, "auto")
        send_control(["settings", "set", "language", val])
        self.refresh_state()

    def _on_welcome_menubar(self, sw: Gtk.Switch, _pspec: Any) -> None:
        if self._updating_ui:
            return
        send_control(["settings", "set", "show-menu-bar-icon", "true" if sw.get_active() else "false"])
        self.refresh_state()

    def _on_welcome_dedicated(self, sw: Gtk.Switch, _pspec: Any) -> None:
        if self._updating_ui:
            return
        send_control(
            ["settings", "set", "dedicated-caps-lock-mode", "true" if sw.get_active() else "false"]
        )
        self.refresh_state()

    def _on_welcome_finish(self, _btn: Gtk.Button) -> None:
        send_control(["settings", "set", "did-complete-initial-setup", "true"])
        if self._welcome_mode:
            self.root_stack.set_visible_child_name("settings")
            self._welcome_mode = False
        else:
            self.root_stack.set_visible_child_name("settings")
        self.refresh_state()


def main() -> int:
    welcome_only = "--welcome" in sys.argv[1:]
    app = Gtk.Application(application_id="io.github.fuji_mak.CapsomniaSettings")

    def on_activate(a: Gtk.Application) -> None:
        win = a.get_active_window()
        if win is None:
            win = CapsomniaWindow(a, welcome_only=welcome_only)
        elif welcome_only:
            win.root_stack.set_visible_child_name("welcome")
        win.present()

    app.connect("activate", on_activate)
    clean_argv = [sys.argv[0]]
    return app.run(clean_argv)


if __name__ == "__main__":
    sys.exit(main())
