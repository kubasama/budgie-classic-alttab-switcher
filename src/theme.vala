// SPDX-License-Identifier: GPL-2.0-or-later
//
// Colors follow the labwc titlebar theme (on Budgie: the "Labwc Compositor
// Theme" setting), so the switcher matches window headers. Without a labwc
// theme file the GTK theme's colors are used. The selection always uses the
// GTK accent color. ~/.config/budgie-classic-alttab-switcher/style.css goes on top.

namespace AltTab {
	const double BG_ALPHA = 0.90;

	// Layout only; colors are set in load_colors()
	const string BASE_CSS = """
		window.budgie-classic-alttab-switcher { background-color: transparent; }
		window.budgie-classic-alttab-switcher > box {
			border-radius: 10px;
			padding: 10px;
		}
		window.budgie-classic-alttab-switcher .tile {
			padding: 4px;
			border-radius: 6px;
			background-color: transparent;
		}
		window.budgie-classic-alttab-switcher .tile.selected {
			background-color: @theme_selected_bg_color;
		}
		window.budgie-classic-alttab-switcher label.title {
			font-weight: 600;
			margin: 8px 6px 2px 6px;
		}
	""";

	const string GTK_COLORS_CSS = """
		window.budgie-classic-alttab-switcher > box {
			background-color: alpha(@theme_bg_color, 0.90);
			border: 1px solid alpha(@theme_fg_color, 0.08);
		}
		window.budgie-classic-alttab-switcher label { color: @theme_fg_color; }
		window.budgie-classic-alttab-switcher .tile.hover:not(.selected) {
			background-color: alpha(@theme_fg_color, 0.12);
		}
	""";

	public class Theme : Object {
		private Gtk.CssProvider base_provider = new Gtk.CssProvider();
		private Gtk.CssProvider color_provider = new Gtk.CssProvider();
		private Gtk.CssProvider user_provider = new Gtk.CssProvider();
		private GenericArray<FileMonitor> monitors = new GenericArray<FileMonitor>();

		public static string user_css_path() {
			return Path.build_filename(Environment.get_user_config_dir(), "budgie-classic-alttab-switcher", "style.css");
		}

		private static string[] themerc_paths() {
			string cfg = Environment.get_user_config_dir();
			return {
				Path.build_filename(cfg, "budgie-desktop", "labwc", "themerc-override"),
				Path.build_filename(cfg, "labwc", "themerc-override"),
			};
		}

		public Theme(Gdk.Screen screen) {
			try {
				base_provider.load_from_data(BASE_CSS);
			} catch (Error e) {
				warning("CSS: %s", e.message);
			}
			Gtk.StyleContext.add_provider_for_screen(screen, base_provider,
				Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
			Gtk.StyleContext.add_provider_for_screen(screen, color_provider,
				Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
			Gtk.StyleContext.add_provider_for_screen(screen, user_provider,
				Gtk.STYLE_PROVIDER_PRIORITY_USER);

			load_colors();
			load_user_css();

			// Watch the folders: themerc-override is often replaced as a symlink
			foreach (unowned string path in themerc_paths()) watch(Path.get_dirname(path));
			watch(Path.get_dirname(user_css_path()));
		}

		private void watch(string dir) {
			try {
				var m = File.new_for_path(dir).monitor_directory(FileMonitorFlags.WATCH_MOVES, null);
				m.changed.connect(on_dir_changed);
				monitors.add(m);
			} catch (Error e) {
				debug("not watching %s: %s", dir, e.message);
			}
		}

		private void on_dir_changed(File file, File? other, FileMonitorEvent event) {
			string name = file.get_basename();
			if (name == "style.css") {
				load_user_css();
			} else if (name == "themerc-override") {
				load_colors();
			}
		}

		// "#rgb", "#rrggbb" or "#rrggbbaa" -> "rgba(r,g,b,a)", alpha multiplied by `alpha`
		private static string? to_rgba(string? hex, double alpha) {
			if (hex == null) return null;
			string h = hex.strip();
			if (!h.has_prefix("#")) return null;
			h = h.substring(1);
			if (h.length == 3) h = "%c%c%c%c%c%c".printf(h[0], h[0], h[1], h[1], h[2], h[2]);
			if (h.length != 6 && h.length != 8) return null;

			uint64 r, g, b, a = 255;
			if (!uint64.try_parse(h.substring(0, 2), out r, null, 16)) return null;
			if (!uint64.try_parse(h.substring(2, 2), out g, null, 16)) return null;
			if (!uint64.try_parse(h.substring(4, 2), out b, null, 16)) return null;
			if (h.length == 8 && !uint64.try_parse(h.substring(6, 2), out a, null, 16)) return null;

			// Locale-independent decimal point
			char[] buf = new char[double.DTOSTR_BUF_SIZE];
			unowned string alpha_text = (a / 255.0 * alpha).to_str(buf);
			return "rgba(%d,%d,%d,%s)".printf((int) r, (int) g, (int) b, alpha_text);
		}

		private static HashTable<string, string>? read_themerc() {
			foreach (unowned string path in themerc_paths()) {
				string contents;
				try {
					if (!FileUtils.get_contents(path, out contents)) continue;
				} catch (Error e) {
					continue;
				}
				var values = new HashTable<string, string>(str_hash, str_equal);
				foreach (unowned string line in contents.split("\n")) {
					string l = line.strip();
					if (l.has_prefix("#")) continue;
					int c = l.index_of(":");
					if (c <= 0) continue;
					values.insert(l.substring(0, c).strip(), l.substring(c + 1).strip());
				}
				debug("colors from %s", path);
				return values;
			}
			return null;
		}

		private void load_colors() {
			string css = GTK_COLORS_CSS;

			var t = read_themerc();
			if (t != null) {
				string? bg_hex = t.lookup("window.active.title.bg.color") ?? t.lookup("osd.bg.color");
				string? fg_hex = t.lookup("window.active.label.text.color") ?? t.lookup("osd.label.text.color");
				string? bg = to_rgba(bg_hex, BG_ALPHA);
				string? fg = to_rgba(fg_hex, 1.0);
				string? hover = to_rgba(fg_hex, 0.12);
				string? edge = to_rgba(fg_hex, 0.08);
				if (bg != null && fg != null) {
					css = """
						window.budgie-classic-alttab-switcher > box {
							background-color: %s;
							border: 1px solid %s;
						}
						window.budgie-classic-alttab-switcher label { color: %s; }
						window.budgie-classic-alttab-switcher .tile.hover:not(.selected) { background-color: %s; }
					""".printf(bg, edge, fg, hover);
				}
			}

			try {
				color_provider.load_from_data(css);
			} catch (Error e) {
				warning("color CSS: %s", e.message);
			}
		}

		private void load_user_css() {
			try {
				if (FileUtils.test(user_css_path(), FileTest.EXISTS)) {
					user_provider.load_from_path(user_css_path());
				} else {
					user_provider.load_from_data("");
				}
			} catch (Error e) {
				warning("%s: %s", user_css_path(), e.message);
			}
		}
	}
}
