# Changelog

## 2.2.0

- **Quick switches on the HUD.** Two icons next to the coin turn on or off with one click, without opening the options:
  - **Lures:** apply your best lure automatically.
  - **Focus mode:** effects up, music and ambience muted, so you hear the splash.
  - They show in colour when on and grey when off, and change the same options as the options page.
- **Session stats** on the HUD: catches, catches per hour, and what they're worth per hour. Point at them for the details, or type `/fishful session`. A session survives `/reload` and starts over after 30 minutes without fishing (or with `/fishful session reset`).
- **New HUD page in the options:**
  - Lock the HUD in place (also `/fishful lock`) and pick its size, from 80% to 130%. It stays where you put it.
  - Choose which parts it shows: what to press next, the lure timer, Fishing skill, this water, session stats, the coin and each quick switch. It gets smaller to fit, in height and width.
  - Showing the HUD, only with the pole, and centring it moved here from General.
- **Sound mode is now Focus mode** (`/fishful focus`; `/fishful sound` still works). Your setting carries over.
- Focus mode and the fishing tweaks now apply right away if you change them while fishing, instead of on the next cast.
- **Attacked with the bobber out:** the Weapon key, the weapon card and Fish (in combat) now stop the fishing first, so one press puts your weapon on. Addons can't cancel a cast by themselves, so this needs that one press when the weapon doesn't go on by itself.

## 2.1.0 — First public release

- **One key to fish.** Each press does the next step:
  - It puts on the pole and your fishing gear.
  - It applies the best lure.
  - It casts.
  - With the bobber out, it reels in.
- **Weapon key** puts your weapon and usual gear back on.
- **When attacked with the pole on:**
  - Your weapon goes back on by itself, with a small notice.
  - If the game doesn't allow it, a card with your weapon appears instead.
- **Fishing HUD**, shown while you hold the pole:
  - Status and what to press next.
  - Lure timer.
  - Fishing skill.
  - Escapes in this water.
  - What you just caught.
- **Catch value** with Auctionator: the best use of everything you fish (vendor, auction house, cooking or any profession), with recipes worth learning. It shows in tooltips, in the chat and in the window.
- **Window** with Catch value, Fishing gear and Recipes tabs.
- **Options** in their own pages, with an explanation under each option. Keys can be set right there, and an action can have several keys.
- **Hints:** why a fish got away, lure ran out, bobber marker, sound mode.
- **Languages:** English, Español, Deutsch, Français and Português.
