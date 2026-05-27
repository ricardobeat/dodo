// dodo — a Checkvist-style outliner TUI built on the milktea framework.
//
// Two screens:
//   LISTS  — pick / create / rename / delete your lists
//   ITEMS  — the outline for one list
//
// Keys (ITEMS screen):
//   ↑/↓ or j/k   move          space        toggle complete
//   tab          indent        shift+tab    outdent
//   enter        new item (and start typing it)
//   e            edit item     d            delete item
//   esc          back to lists q / ctrl+c   quit (saves)
module dodo;

import std::io;
import milktea;
import glaze;

enum Screen : int { LISTS, ITEMS, SETUP }
enum Mode : int { NORMAL, EDIT }

struct App {
	TodoLists lists;
	Screen screen;
	Mode mode;
	Storage storage;  // where lists.txt is read from / written to
	bool configured;  // a storage choice has been made (don't save before this)
	int list_cursor;  // selection on the LISTS screen
	int active_list;  // which list is open on the ITEMS screen
	int item_cursor;  // selection on the ITEMS screen
	int list_scroll;
	int item_scroll;
	int width;
	int height;
}

fn String App.data_dir(App* self) => data_dir(self.storage);

// --- lifecycle -------------------------------------------------------------

fn milktea::Cmd App.init(App* self) @dynamic {
	self.lists.init(mem);
	self.width = 80;
	self.height = 24;

	Storage s;
	if (load_pref(&s)) {
		// Returning user: use the remembered storage.
		self.use_storage(s);
	} else if (icloud_available()) {
		// First run with iCloud available: ask before doing anything.
		self.screen = Screen.SETUP;
	} else {
		// First run, no iCloud: default to local and remember it.
		save_pref(Storage.LOCAL);
		self.use_storage(Storage.LOCAL);
	}
	return null;
}

// Adopt a storage choice and load whatever lists already live there.
fn void App.use_storage(App* self, Storage s) {
	self.storage = s;
	self.configured = true;
	load_all(self.data_dir(), &self.lists);
	self.screen = Screen.LISTS;
	self.list_cursor = 0;
}

fn milktea::Cmd App.update(App* self, milktea::Msg msg) @dynamic {
	if (msg.kind == milktea::MsgKind.WINDOW_SIZE) {
		self.width = msg.window_size.width;
		self.height = msg.window_size.height;
		return null;
	}
	if (msg.kind != milktea::MsgKind.KEY) return null;

	milktea::KeyMsg k = msg.key;

	// First-run storage prompt takes over the keyboard until answered.
	if (self.screen == Screen.SETUP) return self.update_setup(k);

	// Global shortcuts.
	if (k.code == milktea::KeyCode.CTRL_C) {
		save_all(self.data_dir(), &self.lists);
		return milktea::quit();
	}
	if (k.code == milktea::KeyCode.RUNE && k.rune == 's' && k.ctrl) {
		save_all(self.data_dir(), &self.lists);
		return null;
	}

	if (self.screen == Screen.ITEMS) return self.update_items(k);
	return self.update_lists(k);
}

// --- SETUP screen (first-run storage choice) -------------------------------

fn milktea::Cmd App.update_setup(App* self, milktea::KeyMsg k) {
	switch (k.code) {
		case milktea::KeyCode.ENTER:
			self.use_storage(Storage.ICLOUD); // enter = the suggested "yes, sync"
			save_pref(Storage.ICLOUD);
		case milktea::KeyCode.CTRL_C:
		case milktea::KeyCode.ESC:
			return milktea::quit(); // not answered — ask again next launch
		case milktea::KeyCode.RUNE:
			switch (k.rune) {
				case 'y':
					self.use_storage(Storage.ICLOUD);
					save_pref(Storage.ICLOUD);
				case 'n':
					self.use_storage(Storage.LOCAL);
					save_pref(Storage.LOCAL);
				case 'q':
					return milktea::quit();
				default:
			}
		default:
	}
	return null;
}

// --- LISTS screen ----------------------------------------------------------

fn milktea::Cmd App.update_lists(App* self, milktea::KeyMsg k) {
	if (self.mode == Mode.EDIT) {
		TodoList* tl = self.lists.get_ref((sz)self.list_cursor);
		switch (k.code) {
			case milktea::KeyCode.ENTER:
				finish_name(tl);
				self.open_list(self.list_cursor);
			case milktea::KeyCode.ESC:
				finish_name(tl);
				self.mode = Mode.NORMAL;
			case milktea::KeyCode.BACKSPACE:
				sz l = tl.name.len();
				if (l > 0) tl.name.chop(l - 1);
			case milktea::KeyCode.RUNE:
				tl.name.append_char(k.rune);
			default:
		}
		return null;
	}

	int n = self.list_count();
	switch (k.code) {
		case milktea::KeyCode.UP:
			if (self.list_cursor > 0) self.list_cursor--;
		case milktea::KeyCode.DOWN:
			if (self.list_cursor < n - 1) self.list_cursor++;
		case milktea::KeyCode.ENTER:
			if (n > 0) self.open_list(self.list_cursor);
		case milktea::KeyCode.ESC:
			save_all(self.data_dir(), &self.lists);
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			switch (k.rune) {
				case 'q':
					save_all(self.data_dir(), &self.lists);
					return milktea::quit();
				case 'j': if (self.list_cursor < n - 1) self.list_cursor++;
				case 'k': if (self.list_cursor > 0) self.list_cursor--;
				case 'n': self.new_list();
				case 'r': if (n > 0) self.mode = Mode.EDIT;
				case 'd': self.delete_list();
				default:
			}
		default:
	}
	return null;
}

fn void App.new_list(App* self) {
	TodoList tl;
	tl.name = dstring::new(mem, "");
	tl.items.init(mem);
	self.lists.push(tl);
	self.list_cursor = self.list_count() - 1;
	self.mode = Mode.EDIT;
}

fn void App.delete_list(App* self) {
	if (self.list_count() == 0) return;
	TodoList* tl = self.lists.get_ref((sz)self.list_cursor);
	foreach (&it : tl.items) it.text.free();
	tl.items.free();
	tl.name.free();
	self.lists.remove_at((sz)self.list_cursor);
	self.clamp_list_cursor();
}

fn void App.open_list(App* self, int idx) {
	self.active_list = idx;
	self.item_cursor = 0;
	self.item_scroll = 0;
	self.screen = Screen.ITEMS;
	self.mode = Mode.NORMAL;

	// An empty list opens with a fresh bullet ready to type into.
	TodoList* tl = self.lists.get_ref((sz)idx);
	if (tl.items.len() == 0) {
		Item it;
		it.text = dstring::new(mem, "");
		tl.items.push(it);
		self.mode = Mode.EDIT;
	}
}

// --- ITEMS screen ----------------------------------------------------------

fn milktea::Cmd App.update_items(App* self, milktea::KeyMsg k) {
	TodoList* tl = self.cur_list();
	if (tl == null) {
		self.screen = Screen.LISTS;
		return null;
	}
	int n = (int)tl.items.len();

	if (self.mode == Mode.EDIT) {
		Item* it = self.cur_item(tl);
		if (it == null) {
			self.mode = Mode.NORMAL;
			return null;
		}
		switch (k.code) {
			case milktea::KeyCode.ENTER:
				self.insert_item_below(tl, it.depth); // stays in EDIT — rapid entry
			case milktea::KeyCode.ESC:
				self.mode = Mode.NORMAL;
			case milktea::KeyCode.TAB:
				if (k.shift) { self.outdent(tl); } else { self.indent(tl); }
			case milktea::KeyCode.BACKSPACE:
				sz l = it.text.len();
				if (l > 0) {
					it.text.chop(l - 1);
				} else {
					self.delete_item(tl); // remove an empty item with backspace
					self.mode = Mode.NORMAL;
				}
			case milktea::KeyCode.RUNE:
				it.text.append_char(k.rune);
			default:
		}
		return null;
	}

	switch (k.code) {
		case milktea::KeyCode.UP:
			if (self.item_cursor > 0) self.item_cursor--;
		case milktea::KeyCode.DOWN:
			if (self.item_cursor < n - 1) self.item_cursor++;
		case milktea::KeyCode.TAB:
			if (k.shift) { self.outdent(tl); } else { self.indent(tl); }
		case milktea::KeyCode.ENTER:
			self.add_item(tl);
		case milktea::KeyCode.ESC:
		case milktea::KeyCode.LEFT:
		case milktea::KeyCode.BACKSPACE:
			self.screen = Screen.LISTS;
		case milktea::KeyCode.RUNE:
			switch (k.rune) {
				case ' ': self.toggle_done(tl);
				case 'j': if (self.item_cursor < n - 1) self.item_cursor++;
				case 'k': if (self.item_cursor > 0) self.item_cursor--;
				case 'e': if (n > 0) self.mode = Mode.EDIT;
				case 'o': self.add_item(tl);
				case 'd': self.delete_item(tl);
				case 'q':
					save_all(self.data_dir(), &self.lists);
					return milktea::quit();
				default:
			}
		default:
	}
	return null;
}

// Create a new item below the cursor (or the first item) and start editing it.
fn void App.add_item(App* self, TodoList* tl) {
	if (tl.items.len() == 0) {
		Item it;
		it.text = dstring::new(mem, "");
		tl.items.push(it);
		self.item_cursor = 0;
		self.mode = Mode.EDIT;
		return;
	}
	self.insert_item_below(tl, self.cur_item(tl).depth);
}

fn void App.insert_item_below(App* self, TodoList* tl, int depth) {
	Item it;
	it.text = dstring::new(mem, "");
	it.depth = depth;
	int pos = self.item_cursor + 1;
	if (pos >= (int)tl.items.len()) {
		tl.items.push(it);
	} else {
		tl.items.insert_at((sz)pos, it);
	}
	self.item_cursor = pos;
	self.mode = Mode.EDIT;
}

fn void App.delete_item(App* self, TodoList* tl) {
	Item* it = self.cur_item(tl);
	if (it == null) return;
	it.text.free();
	tl.items.remove_at((sz)self.item_cursor);
	int n = (int)tl.items.len();
	if (self.item_cursor >= n) self.item_cursor = n - 1;
	if (self.item_cursor < 0) self.item_cursor = 0;
}

fn void App.toggle_done(App* self, TodoList* tl) {
	Item* it = self.cur_item(tl);
	if (it != null) it.done = !it.done;
}

// You may indent at most one level deeper than the item above you.
fn void App.indent(App* self, TodoList* tl) {
	Item* it = self.cur_item(tl);
	if (it == null || self.item_cursor == 0) return;
	int prev_depth = tl.items.get_ref((sz)(self.item_cursor - 1)).depth;
	if (it.depth <= prev_depth) it.depth++;
}

fn void App.outdent(App* self, TodoList* tl) {
	Item* it = self.cur_item(tl);
	if (it != null && it.depth > 0) it.depth--;
}

// --- small accessors -------------------------------------------------------

fn int App.list_count(App* self) => (int)self.lists.len();

fn TodoList* App.cur_list(App* self) {
	if (self.active_list < 0 || self.active_list >= self.list_count()) return null;
	return self.lists.get_ref((sz)self.active_list);
}

fn Item* App.cur_item(App* self, TodoList* tl) {
	int n = (int)tl.items.len();
	if (self.item_cursor < 0 || self.item_cursor >= n) return null;
	return tl.items.get_ref((sz)self.item_cursor);
}

fn void App.clamp_list_cursor(App* self) {
	int n = self.list_count();
	if (self.list_cursor >= n) self.list_cursor = n - 1;
	if (self.list_cursor < 0) self.list_cursor = 0;
}

fn void finish_name(TodoList* tl) @local {
	if (tl.name.len() == 0) tl.name.append_string("Untitled");
}

// --- per-list colour -------------------------------------------------------

struct ListColor {
	String bg;
	String fg; // a readable text colour for that background
}

// A stable colour for a list, chosen from a small palette by hashing the name.
// The hash is kept bounded (C3 safe builds trap on integer overflow).
fn ListColor list_color(String name) @local {
	String[8] bg = {
		"#d75f5f", "#5f87d7", "#5faf5f", "#d7af5f",
		"#af5fd7", "#5fd7d7", "#d787af", "#8787d7",
	};
	String[8] fg = {
		"#ffffff", "#ffffff", "#000000", "#000000",
		"#ffffff", "#000000", "#000000", "#ffffff",
	};
	uint h = 0;
	foreach (char c : name) h = (h * 31 + (uint)c) % 1000003;
	uint i = h % 8;
	return { bg[i], fg[i] };
}

// --- view ------------------------------------------------------------------

fn milktea::View App.view(App* self) @dynamic {
	if (self.screen == Screen.SETUP) return self.view_setup();
	if (self.screen == Screen.ITEMS) return self.view_items();
	return self.view_lists();
}

fn milktea::View App.view_setup(App* self) {
	glaze::Style title_s = glaze::new_style().foreground(glaze::color_hex("#ffd75f")).set_bold(true);
	glaze::Style body_s  = glaze::new_style().foreground(glaze::color_hex("#cccccc"));
	glaze::Style key_s   = glaze::new_style().foreground(glaze::color_hex("#87ff87")).set_bold(true);
	glaze::Style hint_s  = glaze::new_style().foreground(glaze::color_hex("#666666"));

	DString out = dstring::temp();
	out.append_string(title_s.render("  dodo · setup"));
	out.append_string("\n\n");
	out.append_string(body_s.render("  iCloud Drive is available on this Mac."));
	out.append_char('\n');
	out.append_string(body_s.render("  Store your lists in iCloud so they sync across your Macs?"));
	out.append_string("\n\n");

	out.append_string("  ");
	out.append_string(key_s.render("y"));
	out.append_string(body_s.render(" — yes, use iCloud (synced)"));
	out.append_char('\n');
	out.append_string("  ");
	out.append_string(key_s.render("n"));
	out.append_string(body_s.render(" — no, keep them on this Mac"));
	out.append_string("\n\n");
	out.append_string(hint_s.render("  enter = iCloud · esc = decide later"));

	return milktea::new_alt_screen_view(out.str_view());
}

fn milktea::View App.view_lists(App* self) {
	glaze::Style title_s = glaze::new_style().foreground(glaze::color_hex("#ffd75f")).set_bold(true);
	glaze::Style hint_s  = glaze::new_style().foreground(glaze::color_hex("#666666"));

	DString out = dstring::temp();
	out.append_string(title_s.render("  dodo · lists"));
	out.append_string("\n\n");

	int n = self.list_count();
	if (n == 0) {
		out.append_string(hint_s.render("  [press n to create one]"));
		out.append_char('\n');
	} else {
		int visible = self.height - 5;
		if (visible < 1) visible = 1;
		if (self.list_cursor < self.list_scroll) self.list_scroll = self.list_cursor;
		if (self.list_cursor >= self.list_scroll + visible) self.list_scroll = self.list_cursor - visible + 1;

		int end = self.list_scroll + visible;
		if (end > n) end = n;
		for (int i = self.list_scroll; i < end; i++) {
			TodoList* tl = self.lists.get_ref((sz)i);
			bool is_cursor = i == self.list_cursor;
			bool editing = self.mode == Mode.EDIT && is_cursor;

			// The list's name is drawn in its own colour; the cursor row is bold.
			ListColor lc = list_color(tl.name.str_view());
			glaze::Style name_s = glaze::new_style().foreground(glaze::color_hex(lc.bg)).set_bold(is_cursor);

			DString row = dstring::temp();
			row.append_string(is_cursor ? "> " : "  ");
			if (editing) {
				row.append_string(tl.name.str_view()); // raw — the real cursor marks the caret
			} else {
				row.append_string(tl.name.len() > 0 ? tl.name.str_view() : "(unnamed)");
			}
			out.append_string(name_s.render(row.str_view()));

			if (!editing) {
				int total = (int)tl.items.len();
				int done = 0;
				foreach (&it : tl.items) if (it.done) done++;
				out.append_string(hint_s.render(string::tformat("  (%d/%d)", done, total)));
			}
			out.append_char('\n');
		}
	}

	out.append_char('\n');
	String help = self.mode == Mode.EDIT
		? "  type a name · enter open · esc save name"
		: "  ↑↓ move · enter open · n new · r rename · d delete · q quit";
	out.append_string(hint_s.render(help));

	milktea::View v = milktea::new_alt_screen_view(out.str_view());
	if (self.mode == Mode.EDIT && self.list_count() > 0) {
		TodoList* etl = self.lists.get_ref((sz)self.list_cursor);
		int cy = 2 + (self.list_cursor - self.list_scroll);            // title + blank line
		int cx = 2 + glaze::string_width(etl.name.str_view());        // "> " marker
		v = v.set_cursor_shape(cx, cy, milktea::CursorShape.CURSOR_BLOCK, true);
	}
	return v;
}

fn milktea::View App.view_items(App* self) {
	TodoList* tl = self.cur_list();
	if (tl == null) return self.view_lists();

	glaze::Style cursor_s = glaze::new_style().foreground(glaze::color_hex("#ff5fd7")).set_bold(true);
	glaze::Style item_s   = glaze::new_style().foreground(glaze::color_hex("#cccccc"));
	glaze::Style check_s  = glaze::new_style().foreground(glaze::color_hex("#87ff87")).set_bold(true);
	glaze::Style done_s   = glaze::new_style().foreground(glaze::color_hex("#5f875f"));
	glaze::Style hint_s   = glaze::new_style().foreground(glaze::color_hex("#666666"));

	// The open list's name sits in its own colour, as a background label.
	ListColor lc = list_color(tl.name.str_view());
	glaze::Style title_s = glaze::new_style()
		.foreground(glaze::color_hex(lc.fg))
		.background(glaze::color_hex(lc.bg))
		.set_bold(true)
		.padding(0, 1, 0, 1);

	DString out = dstring::temp();
	String name = tl.name.len() > 0 ? tl.name.str_view() : "(unnamed)";
	out.append_string("  ");
	out.append_string(title_s.render(name));
	out.append_string("\n\n");

	int n = (int)tl.items.len();
	if (n == 0) {
		out.append_string(hint_s.render("  [press enter to add an item]"));
		out.append_char('\n');
	} else {
		int visible = self.height - 5;
		if (visible < 1) visible = 1;
		if (self.item_cursor < self.item_scroll) self.item_scroll = self.item_cursor;
		if (self.item_cursor >= self.item_scroll + visible) self.item_scroll = self.item_cursor - visible + 1;

		int end = self.item_scroll + visible;
		if (end > n) end = n;
		for (int i = self.item_scroll; i < end; i++) {
			Item* it = tl.items.get_ref((sz)i);
			bool is_cursor = i == self.item_cursor;
			glaze::Style base = is_cursor ? cursor_s : item_s;

			// marker + indent + opening bracket, in the row's base colour.
			DString pre = dstring::temp();
			pre.append_string(is_cursor ? "> " : "  ");
			for (int d = 0; d < it.depth * 2; d++) pre.append_char(' ');
			pre.append_char('[');
			out.append_string(base.render(pre.str_view()));

			// checkbox glyph — a light-green ✓ when complete.
			out.append_string(it.done ? check_s.render("✓") : base.render(" "));
			out.append_string(base.render("] "));

			// item text — crossed out (SGR 9) when complete.
			DString txt = dstring::temp();
			txt.append_string(it.text.str_view());
			if (it.done) {
				out.append_string("\x1b[9m");
				out.append_string(done_s.render(txt.str_view()));
			} else {
				out.append_string(base.render(txt.str_view()));
			}
			out.append_char('\n');
		}
	}

	out.append_char('\n');
	String help = self.mode == Mode.EDIT
		? "  type · enter new item · tab indent · ⇧tab outdent · esc done"
		: "  ↑↓ move · space ✓ · tab indent · ⇧tab out · enter add · e edit · d del · esc back";
	out.append_string(hint_s.render(help));

	milktea::View v = milktea::new_alt_screen_view(out.str_view());
	if (self.mode == Mode.EDIT) {
		Item* eit = self.cur_item(tl);
		if (eit != null) {
			int cy = 2 + (self.item_cursor - self.item_scroll);                       // title + blank line
			int cx = 6 + eit.depth * 2 + glaze::string_width(eit.text.str_view());    // "> " + indent + "[x] "
			v = v.set_cursor_shape(cx, cy, milktea::CursorShape.CURSOR_BLOCK, true);
		}
	}
	return v;
}

// --- entry point -----------------------------------------------------------

fn int main() {
	App app = {};
	if (catch err = milktea::@run_program(&app)) {
		io::printfn("Error: %s", err);
		return 1;
	}
	if (app.configured) {
		save_all(app.data_dir(), &app.lists);
		io::printn("saved · bye");
	} else {
		io::printn("bye");
	}
	return 0;
}
