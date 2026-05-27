// dodo — data model and persistence.
//
// Lists are stored in a single tab-delimited file (lists.txt) under either the
// local data dir ($XDG_DATA_HOME/dodo or ~/.local/share/dodo) or, if the user
// opts in, the macOS iCloud Drive folder so they sync across Macs for free.
// The storage choice is remembered in ~/.config/dodo/config.
//
// File format, one record per line:
//   L<TAB><list name>
//   I<TAB><depth><TAB><done 0|1><TAB><item text>
// Item text never contains tabs or newlines (TAB indents, ENTER makes a new
// item), so the delimiter is unambiguous.
module dodo;

import std::collections::list;
import std::io;
import std::os::env;

struct Item {
	DString text;
	int depth;
	bool done;
}

alias ItemList = List{Item};

struct TodoList {
	DString name;
	ItemList items;
}

alias TodoLists = List{TodoList};

// Where the lists file lives. ICLOUD uses the macOS iCloud Drive folder so the
// data syncs across the user's Macs for free.
enum Storage : int { LOCAL, ICLOUD }

// --- paths -----------------------------------------------------------------

fn String home_dir() @local => env::tget_var("HOME") ?? "";

// macOS iCloud Drive container. Files placed here sync across the user's Macs.
fn String icloud_root() @local {
	return string::tformat("%s/Library/Mobile Documents/com~apple~CloudDocs", home_dir());
}

// True when iCloud Drive is enabled on this Mac (the container exists).
fn bool icloud_available() {
	String home = home_dir();
	if (home.len == 0) return false;
	return file::is_dir(icloud_root());
}

// Directory holding lists.txt for the chosen storage (temp-allocated string).
fn String data_dir(Storage s) {
	if (s == Storage.ICLOUD) return string::tformat("%s/dodo", icloud_root());
	String xdg = env::tget_var("XDG_DATA_HOME") ?? "";
	if (xdg.len > 0) return string::tformat("%s/dodo", xdg);
	String home = home_dir();
	if (home.len > 0) return string::tformat("%s/.local/share/dodo", home);
	return ".";
}

// --- preference (which storage to use) -------------------------------------

// The preference lives locally (it can differ per machine), in the standard
// config dir: $XDG_CONFIG_HOME/dodo/config or ~/.config/dodo/config.
fn String config_dir() @local {
	String xdg = env::tget_var("XDG_CONFIG_HOME") ?? "";
	if (xdg.len > 0) return string::tformat("%s/dodo", xdg);
	String home = home_dir();
	if (home.len > 0) return string::tformat("%s/.config/dodo", home);
	return ".";
}

// Reads the saved storage preference. Returns false if none has been set yet.
fn bool load_pref(Storage* out) {
	@pool() {
		String path = string::tformat("%s/config", config_dir());
		if (!file::exists(path)) return false;
		char[]? raw = file::load(tmem, path);
		if (catch raw) return false;
		*out = ((String)raw).trim().starts_with("icloud") ? Storage.ICLOUD : Storage.LOCAL;
		return true;
	};
}

fn void save_pref(Storage s) {
	@pool() {
		String dir = config_dir();
		if (catch path::mkdir(dir, true)) {}
		String val = s == Storage.ICLOUD ? "icloud\n" : "local\n";
		if (catch file::save(string::tformat("%s/config", dir), val)) {}
	};
}

// --- persistence -----------------------------------------------------------

fn void save_all(String dir, TodoLists* lists) {
	@pool() {
		// Best-effort: create the directory tree, ignore "already exists".
		if (catch path::mkdir(dir, true)) {}

		DString out = dstring::temp();
		foreach (&tl : *lists) {
			out.append_string(string::tformat("L\t%s\n", tl.name.str_view()));
			foreach (&it : tl.items) {
				out.append_string(
					string::tformat("I\t%d\t%d\t%s\n", it.depth, it.done ? 1 : 0, it.text.str_view())
				);
			}
		}
		if (catch file::save(string::tformat("%s/lists.txt", dir), out.str_view())) {}
	};
}

fn void load_all(String dir, TodoLists* lists) {
	@pool() {
		String path = string::tformat("%s/lists.txt", dir);
		if (!file::exists(path)) return;
		char[]? raw = file::load(tmem, path);
		if (catch raw) return;

		sz start = 0;
		for (sz p = 0; p <= raw.len; p++) {
			if (p == raw.len || raw[p] == '\n') {
				if (p > start) parse_line(lists, (String)raw[start:p - start]);
				start = p + 1;
			}
		}
	};
}

fn void parse_line(TodoLists* lists, String line) @local {
	if (line.len < 2 || line[1] != '\t') return;

	if (line[0] == 'L') {
		TodoList tl;
		tl.name = dstring::new(mem, line[2..]);
		tl.items.init(mem);
		lists.push(tl);
		return;
	}

	if (line[0] == 'I') {
		if (lists.len() == 0) return;
		String rest = line[2..]; // "<depth>\t<done>\t<text>"
		sz t1 = index_of(rest, '\t', 0);
		if (t1 < 0) return;
		sz t2 = index_of(rest, '\t', t1 + 1);
		if (t2 < 0) return;

		Item it;
		it.depth = rest[0:t1].to_int() ?? 0;
		it.done = rest[t1 + 1:t2 - t1 - 1] == "1";
		it.text = dstring::new(mem, rest[t2 + 1..]);

		TodoList* tl = lists.get_ref(lists.len() - 1);
		tl.items.push(it);
	}
}

fn sz index_of(String s, char c, sz from) @local {
	for (sz i = from; i < s.len; i++) {
		if (s[i] == c) return i;
	}
	return -1;
}
