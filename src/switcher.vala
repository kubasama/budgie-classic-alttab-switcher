// SPDX-License-Identifier: GPL-2.0-or-later
//
// The switcher window: app icons in centered rows, the selected window's title
// underneath, most recently used window first.

namespace AltTab {
	const int ICON_SIZE = 48;
	const int MAX_PER_ROW = 8;
	const uint MODIFIER_POLL_MS = 50;
	const uint NO_FOCUS_TIMEOUT_MS = 600;
	// If Alt is never seen held after the keyboard arrives, treat it as a quick tap
	const int64 DEFAULT_QUICK_TAP_MS = 250;
	// Right after startup the window list arrives asynchronously
	const int64 STARTUP_GRACE_MS = 2000;
	const uint STARTUP_RETRY_MS = 100;

	class Tile : Gtk.EventBox {
		public unowned Xfw.Window window { get; private set; }
		public signal void clicked();

		public Tile(Xfw.Window window, Icon icon) {
			this.window = window;
			visible_window = true;
			add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK);
			get_style_context().add_class("tile");

			var image = new Gtk.Image.from_gicon(icon, Gtk.IconSize.DIALOG);
			image.pixel_size = ICON_SIZE;
			image.margin = 10;
			add(image);
		}

		public void set_selected(bool selected) {
			if (selected) {
				get_style_context().add_class("selected");
			} else {
				get_style_context().remove_class("selected");
			}
		}

		public override bool enter_notify_event(Gdk.EventCrossing event) {
			get_style_context().add_class("hover");
			return false;
		}

		public override bool leave_notify_event(Gdk.EventCrossing event) {
			get_style_context().remove_class("hover");
			return false;
		}

		public override bool button_release_event(Gdk.EventButton event) {
			clicked();
			return true;
		}
	}

	public class SwitcherWindow : Gtk.Window {
		private Xfw.Screen xscreen;
		private IconResolver icons;
		private Theme theme;
		private GLib.Settings? wm_settings = null;

		private Gtk.Box rows_box;
		private Gtk.Label title_label;
		private GenericArray<Tile> tiles = new GenericArray<Tile>();
		private int selected = -1;

		// Most recently used first. Entries are removed in on_window_closed().
		private List<unowned Xfw.Window> recency = new List<unowned Xfw.Window>();

		private uint poll_id = 0;
		private uint no_focus_id = 0;
		private uint retry_id = 0;
		private bool got_focus = false;
		private bool alt_seen = false;
		private int64 focus_time = 0;
		private int64 started_at = 0;
		private int64 quick_tap_ms = DEFAULT_QUICK_TAP_MS;

		// The window is deliberately not attached to the Gtk.Application: GTK
		// would try to export D-Bus properties on it, which fails for a
		// layer-shell surface. The application stays alive through hold().
		public SwitcherWindow() {
			Object(type: Gtk.WindowType.TOPLEVEL);
		}

		construct {
			started_at = get_monotonic_time();
			decorated = false;
			resizable = false;
			skip_taskbar_hint = true;
			skip_pager_hint = true;

			var visual = get_screen().get_rgba_visual();
			if (visual != null) set_visual(visual);

			// Overlay layer, exclusive keyboard while shown, centered (no anchors)
			GtkLayerShell.init_for_window(this);
			GtkLayerShell.set_layer(this, GtkLayerShell.Layer.OVERLAY);
			GtkLayerShell.set_keyboard_mode(this, GtkLayerShell.KeyboardMode.EXCLUSIVE);
			GtkLayerShell.set_namespace(this, "budgie-classic-alttab-switcher");

			get_style_context().add_class("budgie-classic-alttab-switcher");
			theme = new Theme(get_screen());
			icons = new IconResolver();

			var outer = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
			rows_box = new Gtk.Box(Gtk.Orientation.VERTICAL, 6);
			rows_box.halign = Gtk.Align.CENTER;

			title_label = new Gtk.Label("");
			title_label.halign = Gtk.Align.START;
			title_label.xalign = 0;
			title_label.ellipsize = Pango.EllipsizeMode.END;
			title_label.single_line_mode = true;
			title_label.width_chars = 45;
			title_label.max_width_chars = 45;
			title_label.get_style_context().add_class("title");

			outer.pack_start(rows_box, true, true, 0);
			outer.pack_start(title_label, false, false, 0);
			outer.show_all();
			add(outer);

			// The "Show all windows in tab switcher" option, where Budgie provides it
			var src = SettingsSchemaSource.get_default();
			if (src != null && src.lookup("com.solus-project.budgie-wm", true) != null) {
				wm_settings = new GLib.Settings("com.solus-project.budgie-wm");
			}

			string? env = Environment.get_variable("BUDGIE_CLASSIC_ALTTAB_SWITCHER_QUICK_MS");
			if (env != null) quick_tap_ms = int64.max(0, int64.parse(env));

			xscreen = Xfw.Screen.get_default();

			// Wayland doesn't expose stacking order; this is only a starting guess
			unowned List<Xfw.Window>? stacked = xscreen.get_windows_stacked();
			if (stacked != null) {
				foreach (unowned Xfw.Window w in stacked) recency.prepend(w);
			}

			xscreen.window_opened.connect(on_window_opened);
			xscreen.window_closed.connect(on_window_closed);
			xscreen.active_window_changed.connect(on_active_window_changed);
		}

		public override void destroy() {
			stop_watchers();
			if (retry_id != 0) {
				Source.remove(retry_id);
				retry_id = 0;
			}
			if (xscreen != null) {
				SignalHandler.disconnect_by_data(xscreen, this);
			}
			clear_tiles();
			base.destroy();
		}

		/* ---- window tracking ---- */

		private void on_window_opened(Xfw.Window w) {
			if (recency.index(w) < 0) recency.prepend(w);
		}

		// prev is NULL when nothing was focused before
		private void on_active_window_changed(Xfw.Window? prev) {
			unowned Xfw.Window? active = xscreen.get_active_window();
			if (active == null) return;
			recency.remove(active);
			recency.prepend(active);
		}

		private void on_window_closed(Xfw.Window w) {
			recency.remove(w);
			if (!get_visible()) return;

			// Rebuild without it, keeping the same selection if possible
			unowned Xfw.Window? keep = null;
			if (selected >= 0 && selected < tiles.length && tiles[selected].window != w) {
				keep = tiles[selected].window;
			}
			rebuild();
			if (tiles.length == 0) {
				close_switcher();
				return;
			}
			int idx = 0;
			for (int i = 0; i < tiles.length; i++) {
				if (tiles[i].window == keep) idx = i;
			}
			select_index(idx);
		}

		private bool all_workspaces() {
			return wm_settings != null && wm_settings.get_boolean("show-all-windows-tabswitcher");
		}

		private unowned Xfw.Workspace? active_workspace() {
			unowned List<Xfw.WorkspaceGroup>? groups =
				xscreen.get_workspace_manager().list_workspace_groups();
			if (groups == null) return null;
			return groups.data.get_active_workspace();
		}

		// Compositors that don't report workspaces (like labwc today) show every window
		private bool include(Xfw.Window w) {
			if (w.is_skip_tasklist() || w.is_skip_pager()) return false;
			if (all_workspaces()) return true;

			unowned Xfw.Workspace? active = active_workspace();
			unowned Xfw.Workspace? ws = w.get_workspace();
			if (active == null || ws == null) return true;
			return ws.get_id() == active.get_id();
		}

		/* ---- tiles ---- */

		private void clear_tiles() {
			foreach (var row in rows_box.get_children()) row.destroy();
			tiles = new GenericArray<Tile>();
			selected = -1;
			title_label.label = "";
		}

		private void rebuild() {
			clear_tiles();

			foreach (unowned Xfw.Window w in recency) {
				if (!include(w)) continue;
				string source;
				var tile = new Tile(w, icons.resolve(w, out source));
				tile.clicked.connect(on_tile_clicked);
				tiles.add(tile);
			}

			int n = tiles.length;
			int per_row = n.clamp(1, MAX_PER_ROW);
			Gtk.Box? row = null;
			for (int i = 0; i < n; i++) {
				if (i % per_row == 0) {
					row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 6);
					row.halign = Gtk.Align.CENTER;
					row.homogeneous = true;
					rows_box.pack_start(row, false, false, 0);
				}
				row.pack_start(tiles[i], false, false, 0);
			}
			rows_box.show_all();

			resize(1, 1);  // shrink to fit when there are fewer windows than last time
		}

		private void on_tile_clicked(Tile tile) {
			for (int i = 0; i < tiles.length; i++) {
				if (tiles[i] == tile) {
					select_index(i);
					commit();
					return;
				}
			}
		}

		private void select_index(int idx) {
			if (idx < 0 || idx >= tiles.length) return;
			if (selected >= 0 && selected < tiles.length) tiles[selected].set_selected(false);
			selected = idx;
			tiles[idx].set_selected(true);
			title_label.label = (tiles[idx].window.get_name() ?? "").strip();
		}

		/* ---- showing ---- */

		// Open on the monitor of the window being switched away from
		private void place_on_active_monitor() {
			unowned Xfw.Window? active = xscreen.get_active_window();
			if (active == null) return;
			unowned List<Xfw.Monitor>? monitors = active.get_monitors();
			if (monitors == null) return;
			Gdk.Rectangle want = monitors.data.get_logical_geometry();

			var display = get_display();
			for (int i = 0; i < display.get_n_monitors(); i++) {
				var mon = display.get_monitor(i);
				Gdk.Rectangle g = mon.get_geometry();
				if (g.x == want.x && g.y == want.y && g.width == want.width && g.height == want.height) {
					GtkLayerShell.set_monitor(this, mon);
					return;
				}
			}
		}

		/* Called for every Alt+Tab (backwards = Shift+Alt+Tab) */
		public void step(bool backwards) {
			if (get_visible()) {
				int n = tiles.length;
				if (n == 0) {
					close_switcher();
					return;
				}
				int idx = selected < 0 ? 0 : selected;
				select_index(backwards ? (idx - 1 + n) % n : (idx + 1) % n);
				return;
			}

			if (retry_id != 0) return;  // still waiting for the window list
			rebuild();
			int n = tiles.length;
			if (n == 0) {
				// Started by this very key press: windows are still being announced
				if ((get_monotonic_time() - started_at) / 1000 < STARTUP_GRACE_MS) {
					retry_id = Timeout.add(STARTUP_RETRY_MS, () => {
						retry_id = 0;
						step(backwards);
						return Source.REMOVE;
					});
				}
				return;
			}

			// The first press goes to the previously used window
			select_index(n == 1 ? 0 : (backwards ? n - 1 : 1));
			place_on_active_monitor();
			debug("show: %d windows", n);

			got_focus = false;
			alt_seen = false;
			show();
			start_watchers();
		}

		/* Alt+Esc: close without switching */
		public void cancel() {
			if (get_visible()) close_switcher();
		}

		/* ---- noticing that Alt was released ---- */

		private void start_watchers() {
			stop_watchers();
			poll_id = Timeout.add(MODIFIER_POLL_MS, poll_modifiers);
			no_focus_id = Timeout.add(NO_FOCUS_TIMEOUT_MS, check_got_focus);
		}

		private void stop_watchers() {
			if (poll_id != 0) Source.remove(poll_id);
			if (no_focus_id != 0) Source.remove(no_focus_id);
			poll_id = 0;
			no_focus_id = 0;
		}

		private bool poll_modifiers() {
			if (!get_visible()) {
				poll_id = 0;
				return Source.REMOVE;
			}
			if (!got_focus) return Source.CONTINUE;

			var keymap = Gdk.Keymap.get_for_display(get_display());
			var mods = (Gdk.ModifierType) keymap.get_modifier_state();
			if ((mods & Gdk.ModifierType.MOD1_MASK) != 0) {
				alt_seen = true;
				return Source.CONTINUE;
			}

			// Alt released, or never seen held (quick tap, or released before we got the keyboard)
			int64 since_focus_ms = (get_monotonic_time() - focus_time) / 1000;
			if (alt_seen || since_focus_ms >= quick_tap_ms) {
				debug("Alt is up (seen held: %s)", alt_seen.to_string());
				poll_id = 0;
				commit();
				return Source.REMOVE;
			}
			return Source.CONTINUE;
		}

		// Without the keyboard there's no way to see Alt being released
		private bool check_got_focus() {
			no_focus_id = 0;
			if (get_visible() && !got_focus) {
				debug("no keyboard focus, closing");
				close_switcher();
			}
			return Source.REMOVE;
		}

		/* ---- finishing ---- */

		private void commit() {
			if (!get_visible()) return;
			Xfw.Window? target = null;
			if (selected >= 0 && selected < tiles.length) target = tiles[selected].window;

			// Activate before hiding. Hiding first would briefly hand the keyboard
			// back to the previous window, and some apps react by raising
			// themselves again. Both requests use the same Wayland connection, so
			// the compositor handles the activation first.
			if (target != null) {
				debug("activate: %s", target.get_name() ?? "?");
				unowned List<Xfw.Seat>? seats = xscreen.get_seats();
				unowned Xfw.Seat? seat = seats != null ? seats.data : null;
				try {
					target.activate(seat, Gtk.get_current_event_time());
				} catch (Error e) {
					warning("Could not activate window: %s", e.message);
				}
			}
			close_switcher();
		}

		private void close_switcher() {
			stop_watchers();
			hide();
			clear_tiles();
		}

		/* ---- input ---- */

		public override bool focus_in_event(Gdk.EventFocus event) {
			got_focus = true;
			focus_time = get_monotonic_time();
			return base.focus_in_event(event);
		}

		public override bool focus_out_event(Gdk.EventFocus event) {
			// Focus taken away by something else
			if (get_visible() && got_focus) close_switcher();
			return base.focus_out_event(event);
		}

		public override bool key_press_event(Gdk.EventKey event) {
			if ((event.state & Gdk.ModifierType.MOD1_MASK) != 0) alt_seen = true;
			bool shift = (event.state & Gdk.ModifierType.SHIFT_MASK) != 0;

			switch (event.keyval) {
				case Gdk.Key.Tab:
					step(shift);
					break;
				case Gdk.Key.ISO_Left_Tab:
				case Gdk.Key.Left:
				case Gdk.Key.Up:
					step(true);
					break;
				case Gdk.Key.Right:
				case Gdk.Key.Down:
					step(false);
					break;
				case Gdk.Key.Escape:
					close_switcher();
					break;
				case Gdk.Key.Return:
				case Gdk.Key.KP_Enter:
				case Gdk.Key.space:
					commit();
					break;
			}
			return true;
		}

		public override bool key_release_event(Gdk.EventKey event) {
			switch (event.keyval) {
				case Gdk.Key.Alt_L:
				case Gdk.Key.Alt_R:
				case Gdk.Key.Meta_L:
				case Gdk.Key.Meta_R:
					commit();
					break;
			}
			return true;
		}

		/* ---- `list` command ---- */

		public string describe() {
			var sb = new StringBuilder();
			foreach (unowned Xfw.Window w in recency) {
				string source;
				Icon icon = icons.resolve(w, out source);
				sb.append_printf("%s\n", (w.get_name() ?? "").strip());
				sb.append_printf("    %s %s\n", "app ID:", string.joinv(", ", IconResolver.class_ids(w)));
				sb.append_printf("    %s %s (%s)\n", "icon:", icon.to_string() ?? "?", source);
				if (!include(w)) sb.append_printf("    %s\n", "(not shown in the switcher)");
			}
			if (sb.len == 0) sb.append_printf("%s\n", "No windows.");
			sb.append_printf("\n%s %s\n", "Icon overrides:", IconResolver.config_path());
			sb.append_printf("%s %s\n", "Style overrides:", Theme.user_css_path());
			return sb.str;
		}
	}
}
