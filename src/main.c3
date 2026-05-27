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
import xray;

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
	int theme_idx;
	xray::ScreenBuffer* canvas; // the cell grid we paint each frame into
}

fn String App.data_dir(App* self) => data_dir(self.storage);

// --- lifecycle -------------------------------------------------------------

fn milktea::Cmd App.init(App* self) @dynamic {
	self.lists.init(mem);
	self.width = 80;
	self.height = 24;

	int ti = 0;
	if (load_theme_idx(&ti)) self.theme_idx = ti;
	g_theme = get_theme(self.theme_idx);

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

fn void App.on_destroy(App* self) @dynamic {
	if (self.canvas != null) {
		self.canvas.destroy();
		mem::free(self.canvas);
		self.canvas = null;
	}
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

	// Cursor moves over the lists plus a trailing "create new list" row at
	// index n (so the reachable range is 0..n inclusive).
	int n = self.list_count();
	switch (k.code) {
		case milktea::KeyCode.UP:
			if (self.list_cursor > 0) self.list_cursor--;
		case milktea::KeyCode.DOWN:
			if (self.list_cursor < n) self.list_cursor++;
		case milktea::KeyCode.ENTER:
			self.activate_list_row();
		case milktea::KeyCode.ESC:
			save_all(self.data_dir(), &self.lists);
			return milktea::quit();
		case milktea::KeyCode.RUNE:
			switch (k.rune) {
				case 'q':
					save_all(self.data_dir(), &self.lists);
					return milktea::quit();
				case 'j': if (self.list_cursor < n) self.list_cursor++;
				case 'k': if (self.list_cursor > 0) self.list_cursor--;
				case 'n': self.new_list();
				case 'r': if (self.list_cursor < n) self.mode = Mode.EDIT;
				case 'd': if (self.list_cursor < n) self.delete_list();
				case 't':
					self.theme_idx = (self.theme_idx + 1) % 11;
					g_theme = get_theme(self.theme_idx);
					save_theme_idx(self.theme_idx);
				default:
			}
		default:
	}
	return null;
}

// Enter on a list opens it; Enter on the trailing "create new list" row makes one.
fn void App.activate_list_row(App* self) {
	if (self.list_cursor >= self.list_count()) {
		self.new_list();
	} else {
		self.open_list(self.list_cursor);
	}
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

// --- theme -----------------------------------------------------------------

struct Theme {
	String name;
	String title;
	String cursor;
	String item;
	String check;
	String done;
	String hint;
	String border;
	String border2; // if set, border colour gradient end (top→bottom)
	String bg;      // if set, fill canvas background with this colour
	String bg2;     // if set, gradient from bg → bg2 (top→bottom)
	String[8] list;
}

Theme g_theme; // active theme; set once in init and on theme cycle

fn Theme get_theme(int idx) @local {
	Theme t;
	// Default: Dusk
	t.name = "Dusk";
	t.title = "#ffd75f"; t.cursor = "#ff5fd7"; t.item   = "#cccccc";
	t.check = "#87ff87"; t.done   = "#5f875f"; t.hint   = "#888888"; t.border = "#5f0087";
	t.list[0]="#cc1166"; t.list[1]="#1166cc"; t.list[2]="#118844"; t.list[3]="#aa5500";
	t.list[4]="#7711cc"; t.list[5]="#117799"; t.list[6]="#cc4411"; t.list[7]="#9911aa";
	switch (idx % 11) {
		case 1: // Ocean
			t.name = "Ocean";
			t.title = "#87d7ff"; t.cursor = "#00d7d7"; t.item   = "#afd7e7";
			t.check = "#5fffaf"; t.done   = "#5f8787"; t.hint   = "#6087af";
			t.border = "#003d5f"; t.border2 = "#005f87";
			t.bg = "#001a2e"; t.bg2 = "#002a40";
			t.list[0]="#0055aa"; t.list[1]="#0066aa"; t.list[2]="#005588"; t.list[3]="#004477";
			t.list[4]="#115599"; t.list[5]="#006677"; t.list[6]="#004488"; t.list[7]="#005566";
		case 2: // Forest
			t.name = "Forest";
			t.title = "#afff87"; t.cursor = "#5fff87"; t.item   = "#c0d7c0";
			t.check = "#ffff87"; t.done   = "#4f7f4f"; t.hint   = "#7f9070"; t.border = "#005f00";
			t.list[0]="#226622"; t.list[1]="#117733"; t.list[2]="#1a7030"; t.list[3]="#336611";
			t.list[4]="#228811"; t.list[5]="#116644"; t.list[6]="#337722"; t.list[7]="#225511";
		case 3: // Sunset
			t.name = "Sunset";
			t.title = "#ffaf5f"; t.cursor = "#ff7755"; t.item   = "#d7c8b0";
			t.check = "#ffff5f"; t.done   = "#875f3f"; t.hint   = "#907870";
			t.border = "#6a2200"; t.border2 = "#994400";
			t.bg = "#1a0800"; t.bg2 = "#2a1000";
			t.list[0]="#cc4400"; t.list[1]="#994400"; t.list[2]="#aa2211"; t.list[3]="#aa5500";
			t.list[4]="#bb3311"; t.list[5]="#aa4411"; t.list[6]="#883300"; t.list[7]="#995522";
		case 4: // Nord
			t.name = "Nord";
			t.title = "#88c0d0"; t.cursor = "#81a1c1"; t.item   = "#d8dee9";
			t.check = "#a3be8c"; t.done   = "#4c566a"; t.hint   = "#7282aa"; t.border = "#3b4252";
			t.list[0]="#3d608e"; t.list[1]="#2e6e80"; t.list[2]="#2e6262"; t.list[3]="#3e6230";
			t.list[4]="#6a5018"; t.list[5]="#703c28"; t.list[6]="#8a2830"; t.list[7]="#5a2e6a";
		case 5: // Dracula
			t.name = "Dracula";
			t.title = "#f1fa8c"; t.cursor = "#ff79c6"; t.item   = "#f8f8f2";
			t.check = "#50fa7b"; t.done   = "#6272a4"; t.hint   = "#7282b4"; t.border = "#6272a4";
			t.list[0]="#6a30cc"; t.list[1]="#aa2888"; t.list[2]="#cc2222"; t.list[3]="#884c10";
			t.list[4]="#6a6a10"; t.list[5]="#0a8a30"; t.list[6]="#1a6688"; t.list[7]="#3a4a88";
		case 6: // Mono
			t.name = "Mono";
			t.title = "#ffffff"; t.cursor = "#c0c0c0"; t.item   = "#aaaaaa";
			t.check = "#e0e0e0"; t.done   = "#666666"; t.hint   = "#707070"; t.border = "#484848";
			t.list[0]="#505050"; t.list[1]="#585858"; t.list[2]="#484848"; t.list[3]="#606060";
			t.list[4]="#4a4a4a"; t.list[5]="#545454"; t.list[6]="#5c5c5c"; t.list[7]="#464646";
		case 7: // Hot Pink — gradient bg, white text
			t.name = "Hot Pink";
			t.title = "#ffffff"; t.cursor = "#ffff00"; t.item   = "#ffe0f0";
			t.check = "#00ffaa"; t.done   = "#cc66aa"; t.hint   = "#ffaacc";
			t.border = "#aa0055"; t.border2 = "#8800cc";
			t.bg = "#880044"; t.bg2 = "#550077";
			t.list[0]="#aa0044"; t.list[1]="#880088"; t.list[2]="#660099"; t.list[3]="#990033";
			t.list[4]="#7700aa"; t.list[5]="#aa0066"; t.list[6]="#550088"; t.list[7]="#880055";
		case 8: // Solar — gold-to-orange bg, crimson text
			t.name = "Solar";
			t.title = "#8b0000"; t.cursor = "#cc0000"; t.item   = "#3a0000";
			t.check = "#005500"; t.done   = "#7a3300"; t.hint   = "#660000";
			t.border = "#8b0000"; t.border2 = "#aa3300";
			t.bg = "#cc8800"; t.bg2 = "#aa5500";
			t.list[0]="#7a0000"; t.list[1]="#5a1100"; t.list[2]="#882200"; t.list[3]="#440000";
			t.list[4]="#993300"; t.list[5]="#660011"; t.list[6]="#773300"; t.list[7]="#881100";
		case 9: // Midnight — deep dark, neon gradient border, electric text
			t.name = "Midnight";
			t.title = "#00ffff"; t.cursor = "#ff00ff"; t.item   = "#aaaaff";
			t.check = "#00ff88"; t.done   = "#4444aa"; t.hint   = "#6666cc";
			t.border = "#003388"; t.border2 = "#660088";
			t.bg = "#000011"; t.bg2 = "#0a0022";
			t.list[0]="#0044cc"; t.list[1]="#550099"; t.list[2]="#006688"; t.list[3]="#004499";
			t.list[4]="#660066"; t.list[5]="#003377"; t.list[6]="#440088"; t.list[7]="#005588";
		case 10: // Vaporwave — purple-to-teal bg, pink & cyan
			t.name = "Vaporwave";
			t.title = "#ff71ce"; t.cursor = "#01cdfe"; t.item   = "#b967ff";
			t.check = "#05ffa1"; t.done   = "#4a0080"; t.hint   = "#9955cc";
			t.border = "#cc44aa"; t.border2 = "#0088cc";
			t.bg = "#110022"; t.bg2 = "#001e22";
			t.list[0]="#6600aa"; t.list[1]="#005588"; t.list[2]="#880055"; t.list[3]="#004466";
			t.list[4]="#770088"; t.list[5]="#006655"; t.list[6]="#550077"; t.list[7]="#0055aa";
		default:
	}
	return t;
}

// --- per-list colour -------------------------------------------------------

struct ListColor {
	String bg;
	String fg;
}

fn ListColor list_color(String name) @local {
	uint h = 0;
	foreach (char c : name) h = (h * 31 + (uint)c) % 1000003;
	return { g_theme.list[h % 8], "#ffffff" };
}

// --- styles ----------------------------------------------------------------

fn glaze::Style sty_title()  => glaze::new_style().foreground(glaze::color_hex(g_theme.title)).set_bold(true);
fn glaze::Style sty_cursor() => glaze::new_style().foreground(glaze::color_hex(g_theme.cursor)).set_bold(true);
fn glaze::Style sty_item()   => glaze::new_style().foreground(glaze::color_hex(g_theme.item));
fn glaze::Style sty_check()  => glaze::new_style().foreground(glaze::color_hex(g_theme.check)).set_bold(true);
fn glaze::Style sty_done()   => glaze::new_style().foreground(glaze::color_hex(g_theme.done));
fn glaze::Style sty_hint()   => glaze::new_style().foreground(glaze::color_hex(g_theme.hint));

// --- layout scaffolding ----------------------------------------------------
// Every screen is a title row, a blank, a filling body, and a footer pinned to
// the bottom. The body's height drives scrolling; nothing is hand-counted.

struct Frame {
	xray::Rect title;
	xray::Rect body;
	xray::Rect footer;
}

fn void App.apply_bg(App* self) {
	if (g_theme.bg.len == 0) return;
	xray::Color c1 = xray::color_hex(g_theme.bg);
	xray::Color c2 = g_theme.bg2.len > 0 ? xray::color_hex(g_theme.bg2) : c1;
	self.canvas.fill_gradient_v(xray::new_rect(0, 0, self.width, self.height), c1, c2);
}

fn Frame App.frame(App* self) {
	xray::Rect screen = xray::new_rect(0, 0, self.width, self.height);

	// Outer split: bordered area fills everything except the last row (footer).
	xray::Constraint[2] outer_cs = { xray::constraint_fill(1), xray::constraint_len(1) };
	xray::Rect[2] outer;
	xray::layout_v(screen, outer_cs[..], outer[..]);

	// Draw border — gradient if border2 is set, solid otherwise — then inset.
	xray::Border b = xray::rounded_border();
	xray::Rect inner;
	if (g_theme.border2.len > 0) {
		inner = self.canvas.draw_gradient_border(outer[0], b,
			xray::color_hex(g_theme.border), xray::color_hex(g_theme.border2)).inset(2, 1, 2, 1);
	} else {
		inner = self.canvas.draw_border(outer[0], b, border_style()).inset(2, 1, 2, 1);
	}

	// Inner split: title row, blank gap, body.
	xray::Constraint[3] inner_cs = {
		xray::constraint_len(1),  // title
		xray::constraint_len(1),  // blank gap
		xray::constraint_fill(1), // body
	};
	xray::Rect[3] zones;
	xray::layout_v(inner, inner_cs[..], zones[..]);

	return { zones[0], zones[2], outer[1] };
}

// Make sure the cell grid exists and matches the terminal size, then blank it.
// The grid is owned by the App so the View we hand milktea stays valid until
// the next frame (and we don't reallocate every render).
fn void App.ensure_canvas(App* self) {
	sz w = (sz)self.width;
	sz h = (sz)self.height;
	if (self.canvas == null) {
		self.canvas = xray::new_screen_buffer(w, h);
	} else if (self.canvas.width != w || self.canvas.height != h) {
		self.canvas.resize(w, h);
	}
	self.canvas.clear();
}

// Draw one (possibly ANSI-styled) line at row `row` within rect `r`, clipped to
// the rect on both axes — long names are cut, never wrapped.
fn void App.put(App* self, xray::Rect r, int row, String ansi) {
	if (row < 0 || row >= r.h) return;
	self.canvas.render_ansi_string(
		(sz)r.x, (sz)(r.y + row), ansi, xray::default_style(),
		(sz)(r.y + r.h), (sz)(r.x + r.w));
}

fn milktea::View App.present(App* self) {
	sz total = (sz)(self.width * self.height);
	return milktea::new_alt_cell_view(self.canvas.cells[0:total], (sz)self.width, (sz)self.height);
}

// Keep `cursor` within a window of `visible` rows, adjusting `*scroll`.
fn void scroll_into_view(int* scroll, int cursor, int visible) @local {
	if (visible < 1) visible = 1;
	if (cursor < *scroll) *scroll = cursor;
	if (cursor >= *scroll + visible) *scroll = cursor - visible + 1;
}

// --- row builders ----------------------------------------------------------
// Each returns a styled line; the view just places it in a rect.

fn String item_line(Item* it, bool is_cursor) @local {
	glaze::Style base = is_cursor ? sty_cursor() : sty_item();

	DString box = dstring::temp();
	box.append_string(is_cursor ? "▸ " : "  ");
	for (int d = 0; d < it.depth * 2; d++) box.append_char(' ');
	box.append_char('[');

	DString row = dstring::temp();
	row.append_string(base.render(box.str_view()));
	row.append_string(it.done ? sty_check().render("✓") : base.render(" ")); // light-green tick
	row.append_string(base.render("] "));
	if (it.done) {
		row.append_string("\x1b[9m"); // SGR 9 — completed text is struck through
		row.append_string(sty_done().render(it.text.str_view()));
	} else {
		row.append_string(base.render(it.text.str_view()));
	}
	return row.str_view();
}

fn String list_line(TodoList* tl, bool is_cursor, bool editing) @local {
	String name = editing || tl.name.len() > 0 ? tl.name.str_view() : "(unnamed)";
	DString row = dstring::temp();

	if (is_cursor) {
		ListColor lc = list_color(tl.name.str_view());
		glaze::Style hi = glaze::new_style()
			.foreground(glaze::color_hex(lc.fg))
			.background(glaze::color_hex(lc.bg))
			.set_bold(true);
		row.append_string(sty_cursor().render("▸ "));
		row.append_string(hi.render(name));
	} else {
		row.append_string(sty_item().render(string::tformat("  %s", name)));
	}

	if (!editing) {
		int done = 0;
		foreach (&it : tl.items) if (it.done) done++;
		row.append_string(sty_hint().render(string::tformat("  (%d/%d)", done, (int)tl.items.len())));
	}
	return row.str_view();
}

// The "create new list" row at the bottom of the list — same style as list rows.
fn String create_line(bool is_cursor) @local {
	glaze::Style base = is_cursor ? sty_cursor() : sty_hint();
	DString row = dstring::temp();
	row.append_string(base.render(is_cursor ? "▸ create new list" : "  create new list"));
	return row.str_view();
}

// --- views -----------------------------------------------------------------

fn xray::Style border_style() => { .fg = xray::color_hex(g_theme.border) };

// Format a single key hint as "[key] label" with the key in title colour.
fn String kh(String key, String label) @local {
	DString s = dstring::temp();
	s.append_string(sty_title().render(string::tformat("[%s]", key)));
	s.append_string(sty_hint().render(string::tformat(" %s", label)));
	return s.str_view();
}

fn milktea::View App.view(App* self) @dynamic {
	self.ensure_canvas();
	if (self.screen == Screen.SETUP) return self.view_setup();
	if (self.screen == Screen.ITEMS) return self.view_items();
	return self.view_lists();
}

fn milktea::View App.view_setup(App* self) {
	Frame f = self.frame();
	self.put(f.title, 0, sty_title().render("  dodo · setup"));
	self.put(f.body, 0, sty_item().render("  iCloud Drive is available on this Mac."));
	self.put(f.body, 1, sty_item().render("  Store your lists in iCloud so they sync across your Macs?"));
	self.put(f.body, 3, string::tformat("  %s%s", sty_check().render("y"), sty_item().render(" — yes, use iCloud (synced)")));
	self.put(f.body, 4, string::tformat("  %s%s", sty_check().render("n"), sty_item().render(" — no, keep them on this Mac")));
	self.put(f.footer, 0, string::tformat(" %s  %s", kh("enter", "iCloud"), kh("esc", "decide later")));
	self.apply_bg();
	return self.present();
}

fn milktea::View App.view_lists(App* self) {
	Frame f = self.frame();
	self.put(f.title, 0, sty_title().render("  dodo · lists"));

	int n = self.list_count();
	bool has_spacer = n > 0;
	int create_vi  = n + (has_spacer ? 1 : 0);
	int total_vi   = create_vi + 1;
	int vis_cursor = self.list_cursor < n ? self.list_cursor : create_vi;
	scroll_into_view(&self.list_scroll, vis_cursor, f.body.h);
	int end = self.list_scroll + f.body.h;
	if (end > total_vi) end = total_vi;

	// Determine panes up front so list rows go into the right rect immediately.
	bool show_preview = self.width > 80 && self.list_cursor < n;
	xray::Rect list_pane = f.body;
	if (show_preview) {
		xray::Constraint[3] split_cs = {
			xray::constraint_len(36),
			xray::constraint_len(1),
			xray::constraint_fill(1),
		};
		xray::Rect[3] panes;
		xray::layout_h(f.body, split_cs[..], panes[..]);
		list_pane = panes[0];

		// Vertical divider
		xray::Style div_sty = border_style();
		for (int r = 0; r < panes[1].h; r++) {
			self.canvas.set_string((sz)panes[1].x, (sz)(panes[1].y + r), "│", div_sty);
		}

		// Preview items in right pane
		TodoList* ptl = self.lists.get_ref((sz)self.list_cursor);
		int pn = (int)ptl.items.len();
		if (pn == 0) {
			self.put(panes[2], 0, sty_hint().render(" [empty]"));
		} else {
			int pend = pn < panes[2].h ? pn : panes[2].h;
			for (int i = 0; i < pend; i++) {
				self.put(panes[2], i, item_line(ptl.items.get_ref((sz)i), false));
			}
		}
	}

	// List rows into list_pane (left pane when preview shown, full body otherwise)
	for (int vi = self.list_scroll; vi < end; vi++) {
		int row = vi - self.list_scroll;
		if (vi < n) {
			bool is_cursor = vi == self.list_cursor;
			self.put(list_pane, row,
				list_line(self.lists.get_ref((sz)vi), is_cursor, self.mode == Mode.EDIT && is_cursor));
		} else if (vi == create_vi) {
			self.put(list_pane, row, create_line(self.list_cursor == n));
		}
		// blank spacer row (vi == n && has_spacer): nothing drawn
	}

	self.put(f.footer, 0, self.mode == Mode.EDIT
		? string::tformat(" %s  %s  %s", kh("enter", "open"), kh("esc", "save name"), kh("backspace", "delete"))
		: string::tformat(" %s  %s  %s  %s  %s  %s  %s", kh("↑↓", "move"), kh("enter", "open"), kh("n", "new"), kh("r", "rename"), kh("d", "delete"), kh("t", g_theme.name), kh("q", "quit")));

	self.apply_bg();
	milktea::View v = self.present();
	if (self.mode == Mode.EDIT && n > 0) {
		TodoList* etl = self.lists.get_ref((sz)self.list_cursor);
		int cx = list_pane.x + 2 + glaze::string_width(etl.name.str_view());
		int cy = f.body.y + (vis_cursor - self.list_scroll);
		v = v.set_cursor_shape(cx, cy, milktea::CursorShape.CURSOR_BLOCK, true);
	}
	return v;
}

fn milktea::View App.view_items(App* self) {
	TodoList* tl = self.cur_list();
	if (tl == null) return self.view_lists();

	Frame f = self.frame();

	// The open list's name is a background label in its own colour.
	ListColor lc = list_color(tl.name.str_view());
	glaze::Style title_s = glaze::new_style()
		.foreground(glaze::color_hex(lc.fg))
		.background(glaze::color_hex(lc.bg))
		.set_bold(true)
		.padding(0, 1, 0, 1);
	String name = tl.name.len() > 0 ? tl.name.str_view() : "(unnamed)";
	self.put(f.title, 0, string::tformat("  %s", title_s.render(name)));

	int n = (int)tl.items.len();
	if (n == 0) {
		self.put(f.body, 0, sty_hint().render("  [press enter to add an item]"));
	} else {
		scroll_into_view(&self.item_scroll, self.item_cursor, f.body.h);
		int end = self.item_scroll + f.body.h;
		if (end > n) end = n;
		for (int i = self.item_scroll; i < end; i++) {
			self.put(f.body, i - self.item_scroll, item_line(tl.items.get_ref((sz)i), i == self.item_cursor));
		}
	}

	self.put(f.footer, 0, self.mode == Mode.EDIT
		? string::tformat(" %s  %s  %s  %s", kh("enter", "new item"), kh("tab", "indent"), kh("⇧tab", "outdent"), kh("esc", "done"))
		: string::tformat(" %s  %s  %s  %s  %s  %s  %s  %s", kh("↑↓", "move"), kh("space", "✓"), kh("tab", "indent"), kh("enter", "add"), kh("e", "edit"), kh("d", "del"), kh("t", g_theme.name), kh("esc", "back")));

	self.apply_bg();
	milktea::View v = self.present();
	if (self.mode == Mode.EDIT) {
		Item* eit = self.cur_item(tl);
		if (eit != null) {
			int cx = f.body.x + 6 + eit.depth * 2 + glaze::string_width(eit.text.str_view()); // after "> [x] "
			int cy = f.body.y + (self.item_cursor - self.item_scroll);
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
