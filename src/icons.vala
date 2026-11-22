// SPDX-License-Identifier: GPL-2.0-or-later
//
// Finds an icon for a window.
//
// On Wayland, libxfce4windowing only finds an icon when a .desktop file is
// named exactly after the window's app ID, which many apps don't follow. This
// also matches StartupWMClass, the app name and the program name, finds icons
// for Steam games (window class steam_app_<id>), and reads manual overrides
// from icons.conf.

namespace AltTab {
	public class IconResolver : Object {
		// normalized key -> icon, from all installed .desktop files
		private HashTable<string, Icon> by_key = new HashTable<string, Icon>(str_hash, str_equal);
		// Steam app id -> icon, from .desktop files that launch steam://rungameid/<id>
		private HashTable<string, Icon> steam_launchers = new HashTable<string, Icon>(str_hash, str_equal);
		// lowercase app ID -> icon, from icons.conf
		private HashTable<string, Icon> overrides = new HashTable<string, Icon>(str_hash, str_equal);
		private AppInfoMonitor app_monitor;
		private FileMonitor? config_monitor = null;

		public static string config_path() {
			return Path.build_filename(Environment.get_user_config_dir(), "budgie-classic-alttab-switcher", "icons.conf");
		}

		construct {
			rebuild_index();
			load_overrides();

			app_monitor = AppInfoMonitor.get();
			app_monitor.changed.connect(rebuild_index);

			try {
				config_monitor = File.new_for_path(config_path()).monitor_file(FileMonitorFlags.WATCH_MOVES);
				config_monitor.changed.connect(on_config_changed);
			} catch (Error e) {
				debug("not watching %s: %s", config_path(), e.message);
			}
		}

		private void on_config_changed(File file, File? other, FileMonitorEvent event) {
			load_overrides();
		}

		// lowercase, without .desktop / .appimage, spaces as dashes
		private static string normalize(string s) {
			string r = s.strip().down();
			if (r.has_suffix(".desktop")) r = r.substring(0, r.length - ".desktop".length);
			if (r.has_suffix(".appimage")) r = r.substring(0, r.length - ".appimage".length);
			return r.replace(" ", "-");
		}

		// org.example.App -> app
		private static string last_component(string key) {
			int dot = key.last_index_of(".");
			return dot >= 0 ? key.substring(dot + 1) : key;
		}

		private void add_key(string? key, Icon icon) {
			if (key == null || key.strip() == "") return;
			string k = normalize(key);
			if (!by_key.contains(k)) by_key.insert(k, icon);
		}

		private void rebuild_index() {
			by_key.remove_all();
			steam_launchers.remove_all();

			foreach (var info in AppInfo.get_all()) {
				var app = info as DesktopAppInfo;
				if (app == null) continue;
				Icon? icon = app.get_icon();
				if (icon == null) continue;

				// Most specific first: an explicit window class beats names
				add_key(app.get_startup_wm_class(), icon);

				string? id = app.get_id();
				if (id != null) {
					add_key(id, icon);
					add_key(last_component(normalize(id)), icon);
				}

				string? exe = app.get_executable();
				if (exe != null) add_key(Path.get_basename(exe), icon);

				add_key(app.get_name(), icon);

				string? steam_id = steam_id_from_commandline(app.get_commandline());
				if (steam_id != null && !steam_launchers.contains(steam_id)) {
					steam_launchers.insert(steam_id, icon);
				}
			}
			debug("icon index: %u keys", by_key.size());
		}

		private static Icon icon_from_string(string s) {
			if (s.has_prefix("~/")) {
				return new FileIcon(File.new_for_path(Path.build_filename(Environment.get_home_dir(), s.substring(2))));
			}
			if (Path.is_absolute(s)) return new FileIcon(File.new_for_path(s));
			return new ThemedIcon(s);
		}

		// One "app-id = icon-name or /path/to/image" per line, # for comments
		private void load_overrides() {
			overrides.remove_all();
			string contents;
			try {
				if (!FileUtils.get_contents(config_path(), out contents)) return;
			} catch (Error e) {
				return;
			}
			foreach (unowned string line in contents.split("\n")) {
				string l = line.strip();
				if (l == "" || l.has_prefix("#")) continue;
				int eq = l.index_of("=");
				if (eq <= 0) continue;
				string key = l.substring(0, eq).strip().down();
				string val = l.substring(eq + 1).strip();
				if (key != "" && val != "") overrides.insert(key, icon_from_string(val));
			}
		}

		public static string[] class_ids(Xfw.Window w) {
			string[] ids = {};
			unowned string[]? raw = w.get_class_ids();
			if (raw != null) {
				foreach (unowned string s in raw) {
					if (s != null && s != "") ids += s;
				}
			}
			return ids;
		}

		/* ---- Steam ---- */

		private static bool all_digits(string s) {
			if (s == "") return false;
			for (int i = 0; i < s.length; i++) {
				if (!s[i].isdigit()) return false;
			}
			return true;
		}

		// Games started by Steam (Proton in particular) get the window class steam_app_<id>
		private static string? steam_id_from_class(string class_id) {
			string c = class_id.down();
			if (!c.has_prefix("steam_app_")) return null;
			string id = c.substring("steam_app_".length);
			return all_digits(id) ? id : null;
		}

		// "steam steam://rungameid/1091500" -> "1091500"
		private static string? steam_id_from_commandline(string? cmdline) {
			if (cmdline == null) return null;
			int i = cmdline.index_of("rungameid/");
			if (i < 0) return null;
			int start = i + "rungameid/".length;
			int end = start;
			while (end < cmdline.length && cmdline[end].isdigit()) end++;
			return end > start ? cmdline.substring(start, end - start) : null;
		}

		// Native, ~/.steam symlinks and Flatpak installs
		private static string[] steam_roots() {
			string home = Environment.get_home_dir();
			string[] candidates = {
				Path.build_filename(Environment.get_user_data_dir(), "Steam"),
				Path.build_filename(home, ".steam", "steam"),
				Path.build_filename(home, ".steam", "root"),
				Path.build_filename(home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam"),
				Path.build_filename(home, ".var", "app", "com.valvesoftware.Steam", "data", "Steam"),
			};
			string[] roots = {};
			string[] seen = {};
			foreach (unowned string c in candidates) {
				if (!FileUtils.test(c, FileTest.IS_DIR)) continue;
				string real = Posix.realpath(c) ?? c;
				if (real in seen) continue;
				seen += real;
				roots += real;
			}
			return roots;
		}

		private static bool is_hash_name(string name) {
			int dot = name.last_index_of(".");
			if (dot != 40) return false;
			for (int i = 0; i < 40; i++) {
				if (!name[i].isxdigit()) return false;
			}
			return true;
		}

		// The game's small icon in Steam's library cache. Newer Steam keeps it as
		// librarycache/<id>/<sha1>.jpg next to the header and cover art; older
		// Steam used librarycache/<id>_icon.jpg.
		private static Icon? steam_cache_icon(string root, string id) {
			string cache = Path.build_filename(root, "appcache", "librarycache");

			string? best = null;
			int64 best_size = int64.MAX;
			try {
				var dir = File.new_for_path(Path.build_filename(cache, id));
				var e = dir.enumerate_children("standard::name,standard::size", FileQueryInfoFlags.NONE);
				FileInfo? info;
				while ((info = e.next_file()) != null) {
					string name = info.get_name();
					if (!is_hash_name(name)) continue;
					if (info.get_size() < best_size) {
						best_size = info.get_size();
						best = Path.build_filename(cache, id, name);
					}
				}
				e.close();
			} catch (Error err) {
				// no folder for this game
			}
			if (best != null) return new FileIcon(File.new_for_path(best));

			string old = Path.build_filename(cache, id + "_icon.jpg");
			if (FileUtils.test(old, FileTest.EXISTS)) return new FileIcon(File.new_for_path(old));
			return null;
		}

		// Custom icons set in Steam (also used for non-Steam shortcuts)
		private static Icon? steam_grid_icon(string root, string id) {
			try {
				var userdata = File.new_for_path(Path.build_filename(root, "userdata"));
				var e = userdata.enumerate_children("standard::name", FileQueryInfoFlags.NONE);
				FileInfo? info;
				while ((info = e.next_file()) != null) {
					foreach (unowned string ext in new string[] { "png", "jpg", "ico" }) {
						string p = Path.build_filename(root, "userdata", info.get_name(), "config", "grid",
							"%s_icon.%s".printf(id, ext));
						if (FileUtils.test(p, FileTest.EXISTS)) {
							e.close();
							return new FileIcon(File.new_for_path(p));
						}
					}
				}
				e.close();
			} catch (Error err) {
				// no userdata
			}
			return null;
		}

		private Icon? steam_icon(string id, out string source) {
			// Desktop shortcuts made by Steam install steam_icon_<id> into the icon theme
			string themed = "steam_icon_" + id;
			if (Gtk.IconTheme.get_default().has_icon(themed)) {
				source = "Steam shortcut icon";
				return new ThemedIcon(themed);
			}

			Icon? launcher = steam_launchers.lookup(id);
			if (launcher != null) {
				source = "Steam launcher (.desktop)";
				return launcher;
			}

			foreach (unowned string root in steam_roots()) {
				Icon? i = steam_grid_icon(root, id);
				if (i != null) {
					source = "Steam custom icon";
					return i;
				}
				i = steam_cache_icon(root, id);
				if (i != null) {
					source = "Steam library cache";
					return i;
				}
			}
			source = "";
			return null;
		}

		// libxfce4windowing's generic icons (XFW_*_FALLBACK_ICON_NAME)
		private static bool is_fallback(Icon icon) {
			var themed = icon as ThemedIcon;
			if (themed == null) return false;
			unowned string[] names = themed.get_names();
			return names.length > 0 &&
				(names[0] == "application-x-executable-symbolic" || names[0] == "window-maximize-symbolic");
		}

		// `source` says where the icon came from, for the `list` command
		public Icon resolve(Xfw.Window w, out string source) {
			string[] ids = class_ids(w);

			foreach (unowned string id in ids) {
				Icon? o = overrides.lookup(id.down());
				if (o != null) {
					source = "icons.conf";
					return o;
				}
			}

			foreach (unowned string id in ids) {
				string? steam_id = steam_id_from_class(id);
				if (steam_id == null) continue;
				string steam_source;
				Icon? i = steam_icon(steam_id, out steam_source);
				if (i != null) {
					source = steam_source;
					return i;
				}
			}

			unowned Xfw.Application? app = w.get_application();
			Icon? app_icon = app != null ? app.get_gicon() : null;
			if (app_icon != null && !is_fallback(app_icon)) {
				source = "libxfce4windowing";
				return app_icon;
			}

			foreach (unowned string id in ids) {
				string k = normalize(id);
				Icon? i = by_key.lookup(k) ?? by_key.lookup(last_component(k));
				if (i != null) {
					source = ".desktop";
					return i;
				}
			}

			// Last resort: the first word of the window title
			string title = (w.get_name() ?? "").strip();
			if (title != "") {
				Icon? i = by_key.lookup(normalize(title.split(" ")[0]));
				if (i != null) {
					source = "window title";
					return i;
				}
			}

			source = "not found";
			return new ThemedIcon("application-x-executable");
		}
	}
}
