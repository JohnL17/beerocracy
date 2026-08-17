# Beerocracy

A weekly ballot for deciding where to have the beer. One sheet per ISO week:
sign the register, mark the days that work for you, swipe through the places,
watch the tally fill in as everyone else votes. On Monday at 00:00 it resets and
you argue about it all over again.

Days take three answers, not two. Tapping a day cycles it through **yes**,
**maybe** and back to nothing. A maybe counts towards the day exactly like a yes
— it is still a body in the pub — but it is tallied separately, so a day held up
entirely by maybes looks as shaky as it is. Where two days draw, the one more
people are certain about wins.

Elixir · Phoenix LiveView · Ash · SQLite.

## Adding a place

The catalogue is **not** in the database. It lives in
[`priv/places.yml`](priv/places.yml), so adding your local is a pull request
that anyone can review:

```yaml
- slug: hopfenkeller # unique, lowercase, permanent — votes are stored against it
  name: Hopfenkeller
  tagline: Vaulted cellar, twenty taps, no daylight and no regrets.
  emoji: 🍺 # optional
  accent: amber # optional: amber copper gold rust moss plum slate
  beer:
    rating: 5 # 1 (regrettable) to 5 (we would queue for it)
    note: Twenty rotating taps, half of them local.
  food:
    rating: 2
    note: Pretzels and a cheese board. You will not leave full.
  reach:
    office: 6 # a bare number means minutes on foot
    station:
      walk: 9 # give both and the card leads with whichever is
      transit: 5 # quicker, and notes the other underneath
  open: # optional — when the place is open at all
    days: [thursday, friday] # default: all five weekdays
    from: "17:00"
    to: "20:00"
  season: # optional — for pop-ups and summer bars
    from: 2026-06-12
    until: 2026-08-30
  outdoor: true # optional — warns when the winning day looks wet
  tags: [taproom, cellar] # optional
  url: https://example.com/hopfenkeller # optional
```

Each destination under `reach` takes a `walk:` time, a `transit:` time (public
transport), or both — whichever you can honestly fill in. `office: 5` is
shorthand for `office: {walk: 5}`.

Times are measured **from the office** and **from Bern Hauptbahnhof**. They are
door-to-door estimates, not timetable truth — if one is wrong, fix it in a PR.

The file header documents every field. Both pages in the app link straight at
the file on GitHub — the **Add a place** link opens it in GitHub's editor, which
turns into a fork-and-pull-request for anyone without write access.

CI validates the catalogue on each pull request, so a typo fails the build with
a message naming the entry rather than surfacing later as a crash. Check it
yourself first:

```console
$ mix beerocracy.check_places
```

Changing a place's `slug` throws away that place's voting history — rename the
`name` instead, which is free.

## Running it

```console
$ mix setup
$ mix phx.server
```

Then open [`localhost:4000`](http://localhost:4000).

Useful commands:

```console
$ mix test                        # the suite
$ mix precommit                   # compile without warnings, format, test
$ mix beerocracy.check_places      # validate priv/places.yml
```

## Deploying

Every push to `main` runs the tests and, if they pass, builds and pushes a
container to `ghcr.io/<owner>/<repo>:latest`.

```console
$ docker run -d \
    --name beerocracy \
    -v beerocracy:/data \
    -p 4000:4000 \
    -e SECRET_KEY_BASE="$(mix phx.gen.secret)" \
    -e PHX_HOST=beer.example.com \
    ghcr.io/<owner>/<repo>:latest
```

Or with compose:

```yaml
services:
  beerocracy:
    image: ghcr.io/anehx/beerocracy:latest
    restart: unless-stopped
    init: true
    environment:
      PORT: 4200
    env_file: [.env]
    ports: ["4200:4200"]
    volumes: ["./data:/data"]
```

The database is created and migrated on boot.

**About that volume.** SQLite writes the database *and* its `-wal`/`-shm`
companions, so the directory has to be writable, not just the file. A bind
mount like `./data` arrives owned by whoever created it on the host — and when
the directory does not exist yet, Docker creates it as `root`. The container
therefore starts as root just long enough to take ownership of the data
directory, then drops to an unprivileged user for everything else; no
application code runs as root.

If you pin `user:` in compose, the container can no longer fix the ownership
itself, so make the directory match: `chown -R 1000:1000 ./data`. Get it wrong
and it says so on the first line of the log rather than failing as a database
pool timeout.

| Variable          | Default              | What it does                                          |
| ----------------- | -------------------- | ----------------------------------------------------- |
| `SECRET_KEY_BASE` | —, **required**      | Signs session and LiveView tokens                     |
| `DATABASE_PATH`   | `/data/beerocracy.db` | SQLite file; keep it on a volume or votes die on redeploy |
| `PHX_HOST`        | `localhost`          | Public hostname                                       |
| `PHX_SCHEME`      | `https`              | Set to `http` when there is no TLS in front           |
| `PHX_URL_PORT`    | `443` / `80`         | Public port, if it is not the standard one            |
| `PORT`            | `4000`               | Port the container listens on                         |
| `PLACES_FILE`     | bundled `places.yml` | Path to an alternative catalogue                      |
| `REPO_URL`        | this repository      | Where the "add a place" links point — set it if you fork |
| `REPO_BRANCH`     | `main`               | Branch those links open                               |

Mounting your own catalogue with `PLACES_FILE` is an escape hatch for trying
something out; the pull request is the intended route, so everyone can see what
got added.

## How it works

| Where                        | What                                                              |
| ---------------------------- | ----------------------------------------------------------------- |
| `lib/beerocracy/week.ex`     | ISO week keys (`2026-W34`). Votes are scoped by one, which is the whole reset mechanism — nothing is ever deleted. |
| `lib/beerocracy/places.ex`   | Parses and validates `priv/places.yml`, cached against the file's mtime. |
| `lib/beerocracy/voting/`     | Ash resources: `DayVote` and `PlaceVote`, one row per person per week. |
| `lib/beerocracy/ballot.ex`   | Turns votes into a tally and broadcasts changes over PubSub.       |
| `lib/beerocracy_web/live/ballot_live.ex` | The entire UI, plus the swipe gesture as a colocated hook. |

**Only the people who will actually be there choose the place.** A swipe counts
when its owner is marked for the winning day — a maybe is enough. Someone with
no day at all, or only free on other days, has their swipes held as waiting:
kept and displayed rather than binned, and counted the moment the day they are
down for takes the lead.

**The winning day is decided in three steps**, each reached only when the one
before it draws: most people (a maybe counts as a body), then fewest maybes,
then nearest the weekend. The last one always separates them.

**Opening hours are enforced, not decorative.** A place that cannot host the
winning day never wins it — the sheet names the more popular place and says it
is shut, rather than quietly promoting the runner-up. A place whose season has
ended, or whose hours miss the evening entirely, leaves the ballot by itself.

**An outdoor place on a wet day gets a warning**, not a demotion. People are
allowed to sit in the rain; they just should not be surprised by it.

**Past weeks are read back from the votes already stored** — nothing extra is
recorded. Each card shows how long ago we were last there, and the tally lists
recent weeks, so nobody proposes the same pub four Thursdays running.

The swipe deck is **dealt in a different order to every voter**, so the top of
`places.yml` does not get judged while everyone is still interested while the
bottom gets rushed. The order is derived from your name and the week: stable
every time you open the sheet — a deck that reordered itself between swipes
would be unusable — different from everyone else's, and reshuffled next Monday.

A person is identified by the name they type — no accounts, no passwords. It is
kept in `localStorage` so the sheet remembers you next week. **Reset my vote**
in Article I clears your own days and swipes for the week and leaves everyone
else's marks alone; **Undo** under the deck takes back just the last swipe.
