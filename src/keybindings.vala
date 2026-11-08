// SPDX-License-Identifier: GPL-2.0-or-later
//
// `enable`, `disable` and `status`.
//
// Alt+Tab is bound as a Budgie custom shortcut. Budgie's labwc bridge writes
// custom shortcuts into labwc's rc.xml and keeps them whenever it regenerates
// the file. Alt+Tab and Alt+Esc are also removed from the window manager's
// own switching shortcuts; their previous values are saved and restored by
// `disable`.

namespace AltTab.Keybindings {
	const string WM_SCHEMA = "org.gnome.desktop.wm.keybindings";
	const string MK_SCHEMA = "org.buddiesofbudgie.settings-daemon.plugins.media-keys";
	const string CK_SCHEMA = MK_SCHEMA + ".custom-keybinding";
	const string PREFIX = "/org/buddiesofbudgie/settings-daemon/plugins/media-keys/custom-keybindings/";
	const string PATH_NEXT = PREFIX + "custom-classic-alttab-switcher-next/";
	const string PATH_PREV = PREFIX + "custom-classic-alttab-switcher-prev/";
	const string PATH_CANCEL = PREFIX + "custom-classic-alttab-switcher-cancel/";

	string backup_path() {
		return Path.build_filename(Environment.get_user_config_dir(), "budgie-classic-alttab-switcher",
			"wm-keybindings.backup");
	}

	string command(string arg) {
		return Path.build_filename(Config.BINDIR, "budgie-classic-alttab-switcher") + " " + arg;
	}

	GLib.Settings? open_settings(string id) {
		var src = SettingsSchemaSource.get_default();
		if (src == null || src.lookup(id, true) == null) return null;
		return new GLib.Settings(id);
	}

	// Alt+Tab and Alt+Esc, with or without Shift, in any spelling, but not e.g.
	// <Super><Alt>Tab. Alt+Esc has to be taken over too: it is pressed while Alt
	// is still held, and the compositor would otherwise open its own switcher.
	bool is_taken_over(string accel) {
		uint key;
		Gdk.ModifierType mods;
		Gtk.accelerator_parse(accel, out key, out mods);
		if (key != Gdk.Key.Tab && key != Gdk.Key.ISO_Left_Tab && key != Gdk.Key.Escape) return false;
		if ((mods & Gdk.ModifierType.MOD1_MASK) == 0) return false;
		return (mods & ~(Gdk.ModifierType.MOD1_MASK | Gdk.ModifierType.SHIFT_MASK)) == 0;
	}

	// key=value lines; values are GVariant text
	HashTable<string, string> read_backup() {
		var table = new HashTable<string, string>(str_hash, str_equal);
		string contents;
		try {
			if (!FileUtils.get_contents(backup_path(), out contents)) return table;
		} catch (Error e) {
			return table;
		}
		foreach (unowned string line in contents.split("\n")) {
			int eq = line.index_of("=");
			if (eq > 0) table.insert(line.substring(0, eq), line.substring(eq + 1));
		}
		return table;
	}

	void write_backup(HashTable<string, string> table) throws Error {
		DirUtils.create_with_parents(Path.get_dirname(backup_path()), 0755);
		var sb = new StringBuilder();
		foreach (unowned string key in table.get_keys()) {
			sb.append_printf("%s=%s\n", key, table.lookup(key));
		}
		FileUtils.set_contents(backup_path(), sb.str);
	}

	bool shortcut_present(GLib.Settings mk, string path) {
		foreach (unowned string p in mk.get_strv("custom-keybindings")) {
			if (p == path) return true;
		}
		return false;
	}

	void add_shortcut(GLib.Settings mk, string path, string name, string accel, string cmd) {
		var s = new GLib.Settings.with_path(CK_SCHEMA, path);
		s.set_string("name", name);
		s.set_string("binding", accel);
		s.set_string("command", cmd);

		if (!shortcut_present(mk, path)) {
			string[] list = mk.get_strv("custom-keybindings");
			list += path;
			mk.set_strv("custom-keybindings", list);
		}
	}

	void remove_shortcut(GLib.Settings mk, string path) {
		string[] kept = {};
		foreach (unowned string p in mk.get_strv("custom-keybindings")) {
			if (p != path) kept += p;
		}
		mk.set_strv("custom-keybindings", kept);

		var s = new GLib.Settings.with_path(CK_SCHEMA, path);
		s.reset("name");
		s.reset("binding");
		s.reset("command");
	}

	public bool enable(StringBuilder msg) {
		var mk = open_settings(MK_SCHEMA);
		var wm = open_settings(WM_SCHEMA);
		if (mk == null || wm == null) {
			msg.append("Budgie's shortcut settings were not found, so Alt+Tab has to be bound by hand.");
			msg.append("\n");
			msg.append("For labwc, add this to the <keyboard> section of rc.xml:");
			msg.append_printf("\n  <keybind key=\"A-Tab\"><action name=\"Execute\" command=\"%s\" /></keybind>", command("next"));
			msg.append_printf("\n  <keybind key=\"A-S-Tab\"><action name=\"Execute\" command=\"%s\" /></keybind>", command("prev"));
			msg.append_printf("\n  <keybind key=\"A-Escape\"><action name=\"Execute\" command=\"%s\" /></keybind>\n", command("cancel"));
			return false;
		}

		var backup = read_backup();
		var schema = wm.settings_schema;
		foreach (unowned string key in schema.list_keys()) {
			if (!schema.get_key(key).get_value_type().equal(VariantType.STRING_ARRAY)) continue;

			string[] current = wm.get_strv(key);
			string[] kept = {};
			foreach (unowned string accel in current) {
				if (!is_taken_over(accel)) kept += accel;
			}
			if (kept.length == current.length) continue;

			// Keep the oldest value if enable runs more than once
			if (!backup.contains(key)) backup.insert(key, wm.get_value(key).print(false));
			wm.set_strv(key, kept);
			msg.append_printf("  %s\n", "removed from built-in shortcut “%s”".printf(key));
		}
		try {
			write_backup(backup);
		} catch (Error e) {
			msg.append_printf("%s\n", "Warning: could not save %s: %s".printf(backup_path(), e.message));
		}

		add_shortcut(mk, PATH_NEXT, "Classic Alt+Tab Switcher", "<Alt>Tab", command("next"));
		add_shortcut(mk, PATH_PREV, "Classic Alt+Tab Switcher (backwards)", "<Shift><Alt>Tab", command("prev"));
		add_shortcut(mk, PATH_CANCEL, "Classic Alt+Tab Switcher (cancel)", "<Alt>Escape", command("cancel"));
		GLib.Settings.sync();

		msg.append_printf("%s\n", "Alt+Tab now opens the classic switcher.");
		return true;
	}

	public bool disable(StringBuilder msg) {
		var mk = open_settings(MK_SCHEMA);
		var wm = open_settings(WM_SCHEMA);
		if (mk == null || wm == null) {
			msg.append_printf("%s\n", "Budgie's shortcut settings were not found, nothing to undo.");
			return false;
		}

		remove_shortcut(mk, PATH_NEXT);
		remove_shortcut(mk, PATH_PREV);
		remove_shortcut(mk, PATH_CANCEL);

		var backup = read_backup();
		var schema = wm.settings_schema;
		foreach (unowned string key in backup.get_keys()) {
			if (!schema.has_key(key)) continue;
			try {
				wm.set_value(key, Variant.parse(VariantType.STRING_ARRAY, backup.lookup(key)));
				msg.append_printf("  %s\n", "restored “%s”".printf(key));
			} catch (Error e) {
				msg.append_printf("%s\n", "Warning: could not restore %s: %s".printf(key, e.message));
			}
		}
		FileUtils.unlink(backup_path());
		GLib.Settings.sync();

		msg.append_printf("%s\n", "Alt+Tab is back to the compositor's own switcher.");
		return true;
	}

	public bool is_enabled() {
		var mk = open_settings(MK_SCHEMA);
		return mk != null && shortcut_present(mk, PATH_NEXT);
	}
}
