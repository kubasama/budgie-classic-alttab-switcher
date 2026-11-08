// SPDX-License-Identifier: GPL-2.0-or-later
//
// Finds an icon for a window.
//
// On Wayland, libxfce4windowing only finds an icon when a .desktop file is
// named exactly after the window's app ID, which many apps don't follow. This
// also matches StartupWMClass, the app name and the program name, and reads
// manual overrides from icons.conf.

namespace AltTab {
	public class IconResolver : Object {
		// normalized key -> icon, from all installed .desktop files
		private HashTable<string, Icon> by_key = new HashTable<string, Icon>(str_hash, str_equal);
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
