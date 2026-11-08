// SPDX-License-Identifier: GPL-2.0-or-later
//
// A single background instance owns the switcher window. The Alt+Tab shortcut
// runs `budgie-classic-alttab-switcher next`, which GApplication forwards to that
// instance over D-Bus, so the switcher opens without starting a new process.

namespace AltTab {
	string usage() {
		return """Usage: budgie-classic-alttab-switcher [COMMAND]

Without a command, starts the switcher in the background.

Commands:
  next       open the switcher, or select the next window
  prev       open the switcher, or select the previous window
  cancel     close the switcher without switching
  list       show open windows with their app ID and icon
  enable     bind Alt+Tab to this switcher and start it
  disable    give Alt+Tab back to the compositor's switcher
  status     show whether Alt+Tab is bound and the switcher is running
  quit       stop the background switcher
""";
	}

	public class App : Gtk.Application {
		private SwitcherWindow? switcher = null;
		private bool held = false;
		private bool supported = true;

		public App() {
			Object(application_id: Config.APP_ID,
			       flags: ApplicationFlags.HANDLES_COMMAND_LINE);
		}

		protected override void startup() {
			base.startup();
			if (!GtkLayerShell.is_supported()) {
				supported = false;
				return;
			}
			// Exists up front so new config files are noticed without a restart
			DirUtils.create_with_parents(
				Path.build_filename(Environment.get_user_config_dir(), "budgie-classic-alttab-switcher"), 0755);
			switcher = new SwitcherWindow();
		}

		protected override void shutdown() {
			if (switcher != null) {
				switcher.destroy();
				switcher = null;
			}
			base.shutdown();
		}

		private void keep_running() {
			if (!held) {
				hold();
				held = true;
			}
		}

		protected override int command_line(ApplicationCommandLine cl) {
			string[] args = cl.get_arguments();
			string cmd = args.length > 1 ? args[1] : "";

			if (!supported) {
				cl.printerr("%s\n", "This needs a Wayland compositor with layer-shell support, such as labwc.");
				return 1;
			}

			switch (cmd) {
				case "":
					keep_running();
					return 0;
				case "next":
				case "prev":
					keep_running();
					switcher.step(cmd == "prev");
					return 0;
				case "cancel":
					// Bound to Alt+Esc, which also arrives when nothing is open
					if (held) switcher.cancel();
					return 0;
				case "list":
					if (!held) {
						cl.printerr("%s\n", "The switcher is not running.");
						return 1;
					}
					cl.print("%s", switcher.describe());
					return 0;
				case "quit":
					if (held) {
						release();
						held = false;
					}
					quit();
					return 0;
				default:
					// Only reachable from an older or newer instance forwarding its arguments
					cl.printerr("%s\n", "Unknown command: %s".printf(cmd));
					return 1;
			}
		}
	}

	bool daemon_running() {
		try {
			var bus = Bus.get_sync(BusType.SESSION);
			var reply = bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
				"NameHasOwner", new Variant("(s)", Config.APP_ID), new VariantType("(b)"),
				DBusCallFlags.NONE, 1000);
			bool has_owner;
			reply.get("(b)", out has_owner);
			return has_owner;
		} catch (Error e) {
			return false;
		}
	}

	// Start the background instance in its own session, so it keeps running
	// after the terminal that ran `enable` is closed
	void start_daemon() {
		string[] argv = { Path.build_filename(Config.BINDIR, "budgie-classic-alttab-switcher") };
		try {
			Process.spawn_async(null, argv, null,
				SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL,
				() => { Posix.setsid(); }, null);
			stdout.printf("%s\n", "The switcher is running. From now on it starts at login.");
		} catch (SpawnError e) {
			stdout.printf("%s\n", "Could not start the switcher (%s). It starts at your next login.".printf(e.message));
		}
	}

	public static int main(string[] args) {
		string cmd = args.length > 1 ? args[1] : "";
		var msg = new StringBuilder();

		// Commands that don't involve the switcher window
		switch (cmd) {
			case "-h":
			case "--help":
			case "help":
				stdout.printf("%s", usage());
				return 0;
			case "-v":
			case "--version":
				stdout.printf("budgie-classic-alttab-switcher %s\n%s\n", Config.VERSION, Config.WEBSITE);
				return 0;
			case "enable":
				bool ok = Keybindings.enable(msg);
				stdout.printf("%s", msg.str);
				if (ok && !daemon_running()) start_daemon();
				return ok ? 0 : 1;
			case "disable":
				bool ok = Keybindings.disable(msg);
				stdout.printf("%s", msg.str);
				return ok ? 0 : 1;
			case "status":
				stdout.printf("%s %s\n", "Alt+Tab bound:", Keybindings.is_enabled() ? "yes" : "no");
				stdout.printf("%s %s\n", "Switcher running:", daemon_running() ? "yes" : "no");
				return 0;
		}

		switch (cmd) {
			case "":
			case "next":
			case "prev":
			case "cancel":
			case "list":
			case "quit":
				return new App().run(args);
			default:
				stderr.printf("%s\n\n%s", "Unknown command: %s".printf(cmd), usage());
				return 1;
		}
	}
}
