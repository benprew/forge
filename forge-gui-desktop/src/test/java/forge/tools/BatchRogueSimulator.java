package forge.tools;

import java.io.BufferedWriter;
import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.zip.GZIPOutputStream;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import com.google.common.collect.Lists;
import com.google.common.eventbus.Subscribe;

import forge.ai.LobbyPlayerAi;
import forge.deck.CardPool;
import forge.deck.Deck;
import forge.deck.DeckSection;
import forge.item.PaperCard;
import forge.model.FModel;
import forge.game.Game;
import forge.game.GameEndReason;
import forge.game.GameLog;
import forge.game.GameLogEntry;
import forge.game.GameLogFormatter;
import forge.game.GameRules;
import forge.game.GameType;
import forge.game.Match;
import forge.game.card.Card;
import forge.game.event.GameEvent;
import forge.game.event.GameEventGameFinished;
import forge.game.event.GameEventGameOutcome;
import forge.game.event.GameEventPlayerPriority;
import forge.game.event.GameEventSpellAbilityCast;
import forge.game.event.GameEventSpellResolved;
import forge.game.event.GameEventTurnBegan;
import forge.game.phase.PhaseHandler;
import forge.game.phase.PhaseType;
import forge.game.player.Player;
import forge.game.player.RegisteredPlayer;
import forge.game.spellability.SpellAbilityStackInstance;
import forge.game.zone.MagicStack;
import forge.game.zone.ZoneType;
import forge.net.TestUtils;
import forge.util.ThreadUtil;

/**
 * Runs AI-vs-AI matches with random decks from {@code rogue_dck/} and writes
 * one JSONL replay per game (matching the {@code batch-*.jsonl} format used as
 * warm-start AI training data).
 *
 * <pre>
 * java -cp &lt;test-classpath&gt; forge.tools.BatchRogueSimulator \
 *     --decks-dir rogue_dck \
 *     --output-dir batches \
 *     --count 5000 \
 *     --batch-index 1 \
 *     --skill 3 \
 *     --max-turns 50 \
 *     --seed 42
 * </pre>
 */
public final class BatchRogueSimulator {

    public static void main(String[] args) throws Exception {
        // Log uncaught exceptions ourselves — Forge installs a JVM-wide handler
        // that swallows them.
        Thread.setDefaultUncaughtExceptionHandler((t, e) -> {
            System.err.println("[batch] uncaught in " + t.getName() + ":");
            e.printStackTrace(System.err);
        });
        try {
            runMain(args);
        } catch (Throwable t) {
            System.err.println("[batch] fatal:");
            t.printStackTrace(System.err);
            System.exit(1);
        }
    }

    private static void runMain(String[] args) throws Exception {
        Options opts = Options.parse(args);
        System.out.printf("[batch] count=%d decks=%s output=%s seed=%d%n",
                opts.count, opts.decksDir, opts.outputDir, opts.seed);

        Files.createDirectories(opts.outputDir);
        TestUtils.ensureFModelInitialized();

        List<File> decks = listDecks(opts.decksDir);
        if (decks.isEmpty()) {
            throw new IllegalStateException("No .dck files in " + opts.decksDir);
        }
        System.out.printf("[batch] loaded %d deck files%n", decks.size());

        Random rng = new Random(opts.seed);
        long batchTimestamp = System.currentTimeMillis();
        String batchTimestampStr = formatBatchTimestamp(batchTimestamp);

        int wins = 0, losses = 0, draws = 0;
        long t0 = System.nanoTime();
        for (int i = 0; i < opts.count; i++) {
            File deckA = decks.get(rng.nextInt(decks.size()));
            File deckB = decks.get(rng.nextInt(decks.size()));
            long gameSeed = rng.nextLong();

            try {
                String winnerName = runOne(opts, i, batchTimestamp, batchTimestampStr,
                        deckA, deckB, gameSeed);
                if (winnerName == null) draws++;
                else if ("PlayerA".equals(winnerName)) wins++;
                else losses++;
            } catch (Throwable t) {
                System.err.printf("[batch] game %d failed: %s%n", i, t);
                t.printStackTrace();
            }

            if ((i + 1) % 25 == 0 || i + 1 == opts.count) {
                long elapsedMs = (System.nanoTime() - t0) / 1_000_000;
                double rate = (i + 1) * 1000.0 / Math.max(elapsedMs, 1);
                System.out.printf("[batch] %d/%d games (A:%d B:%d D:%d) %.2f games/s%n",
                        i + 1, opts.count, wins, losses, draws, rate);
            }
        }
        System.out.printf("[batch] done. A=%d B=%d draws=%d%n", wins, losses, draws);
    }

    private static String runOne(Options opts, int gameIdx, long batchTs, String batchTsStr,
                                 File deckAFile, File deckBFile, long gameSeed) throws Exception {
        Deck deckA = parseRogueDeck(deckAFile);
        Deck deckB = parseRogueDeck(deckBFile);

        UUID gameUuid = new UUID(gameSeed, batchTs ^ gameIdx);
        UUID idA = new UUID(gameUuid.getMostSignificantBits() ^ 0xA000_0000_0000_0000L,
                            gameUuid.getLeastSignificantBits() ^ 0xA000_0000_0000_0000L);
        UUID idB = new UUID(gameUuid.getMostSignificantBits() ^ 0xB000_0000_0000_0000L,
                            gameUuid.getLeastSignificantBits() ^ 0xB000_0000_0000_0000L);

        List<RegisteredPlayer> players = Lists.newArrayList();
        RegisteredPlayer rpA = new RegisteredPlayer(deckA);
        rpA.setPlayer(new LobbyPlayerAi("PlayerA", null));
        RegisteredPlayer rpB = new RegisteredPlayer(deckB);
        rpB.setPlayer(new LobbyPlayerAi("PlayerB", null));
        players.add(rpA);
        players.add(rpB);

        GameRules rules = new GameRules(GameType.Constructed);
        rules.setGamesPerMatch(1);
        Match match = new Match(rules, players, "BatchRogue");
        Game game = match.createGame();

        String fname = replayFilename(opts.batchIndex, batchTsStr, gameIdx, gameUuid);
        if (opts.gzip) fname += ".gz";
        Path outFile = opts.outputDir.resolve(fname);
        ReplayState state = new ReplayState(game, gameUuid, idA, idB, opts.maxTurns);
        ReplayListener listener = new ReplayListener(state);
        game.subscribeToEvents(listener);

        Instant startedAt = Instant.now();
        CountDownLatch done = new CountDownLatch(1);
        Throwable[] err = new Throwable[1];
        ThreadUtil.invokeInGameThread(() -> {
            try {
                match.startGame(game);
            } catch (Throwable t) {
                err[0] = t;
            } finally {
                done.countDown();
            }
        });
        boolean finished = done.await(opts.gameTimeoutSec, TimeUnit.SECONDS);
        if (!finished) {
            game.setGameOver(GameEndReason.Draw);
            done.await(30, TimeUnit.SECONDS);
        }
        if (err[0] != null) {
            throw new RuntimeException("game " + gameIdx + " failed", err[0]);
        }
        Instant endedAt = Instant.now();

        String winnerName = state.winnerName;
        UUID winnerId = "PlayerA".equals(winnerName) ? idA
                      : "PlayerB".equals(winnerName) ? idB : null;

        try (BufferedWriter w = openWriter(outFile, opts.gzip)) {
            w.write(buildMeta(opts, gameIdx, batchTs, gameSeed,
                    deckAFile, deckBFile, gameUuid, idA, idB,
                    rpA.getStartingLife(), rpB.getStartingLife(),
                    deckA, deckB, startedAt, endedAt,
                    winnerId, winnerName, state.events.size()));
            w.write('\n');
            for (String line : state.events) {
                w.write(line);
                w.write('\n');
            }
        }
        return winnerName;
    }

    /* -------- helpers ------------------------------------------------ */

    /**
     * Parse a deck in the simple {@code NAME:.../N [SET:CN] CardName/SB: ...}
     * format used by the {@code rogue_dck/} corpus. Forge's regular
     * {@code DeckSerializer} expects {@code [Section]} headers and silently
     * fails on this format.
     */
    private static Deck parseRogueDeck(File f) throws IOException {
        List<String> lines = Files.readAllLines(f.toPath(), StandardCharsets.UTF_8);
        String name = f.getName().replaceFirst("\\.dck$", "");
        CardPool main = new CardPool();
        CardPool sb = new CardPool();
        var db = FModel.getMagicDb().getCommonCards();
        int unresolved = 0;
        for (String raw : lines) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("#")) continue;
            if (line.regionMatches(true, 0, "NAME:", 0, 5)) {
                name = line.substring(5).trim();
                continue;
            }
            boolean sideboard = false;
            if (line.regionMatches(true, 0, "SB:", 0, 3)) {
                sideboard = true;
                line = line.substring(3).trim();
            }
            // "N [SET:CN] Card Name" or "N Card Name"
            int sp = line.indexOf(' ');
            if (sp <= 0) continue;
            int qty;
            try { qty = Integer.parseInt(line.substring(0, sp)); }
            catch (NumberFormatException e) { continue; }
            String rest = line.substring(sp + 1).trim();
            if (rest.startsWith("[")) {
                int rb = rest.indexOf(']');
                if (rb < 0) continue;
                rest = rest.substring(rb + 1).trim();
            }
            String cardName = rest;
            PaperCard pc = db.getCard(cardName);
            if (pc == null) { unresolved++; continue; }
            (sideboard ? sb : main).add(pc, qty);
        }
        if (unresolved > 0) {
            System.err.printf("[batch] %s: %d card name(s) could not be resolved%n",
                    f.getName(), unresolved);
        }
        Deck d = new Deck(name);
        d.getMain().addAll(main);
        if (sb.countAll() > 0) {
            d.getOrCreate(DeckSection.Sideboard).addAll(sb);
        }
        return d;
    }

    private static BufferedWriter openWriter(Path outFile, boolean gzip) throws IOException {
        OutputStream os = Files.newOutputStream(outFile);
        if (gzip) {
            os = new GZIPOutputStream(os, 8192);
        }
        return new BufferedWriter(new OutputStreamWriter(os, StandardCharsets.UTF_8));
    }

    private static List<File> listDecks(Path decksDir) throws IOException {
        try (var stream = Files.list(decksDir)) {
            List<File> out = new ArrayList<>();
            stream.filter(p -> p.getFileName().toString().endsWith(".dck"))
                  .sorted()
                  .forEach(p -> out.add(p.toFile()));
            return out;
        }
    }

    private static final DateTimeFormatter BATCH_TS_FMT =
            DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss-SSS").withZone(ZoneOffset.UTC);

    private static String formatBatchTimestamp(long epochMillis) {
        return BATCH_TS_FMT.format(Instant.ofEpochMilli(epochMillis));
    }

    private static String replayFilename(int batchIndex, String batchTs, int gameIdx, UUID gameUuid) {
        return String.format(Locale.ROOT, "batch-%d-%s-%d-%s.jsonl",
                batchIndex, batchTs, gameIdx, gameUuid);
    }

    private static String buildMeta(Options opts, int gameIdx, long batchSeed, long gameSeed,
                                    File deckAFile, File deckBFile,
                                    UUID gameUuid, UUID idA, UUID idB,
                                    int startingLifeA, int startingLifeB,
                                    Deck deckA, Deck deckB,
                                    Instant startedAt, Instant endedAt,
                                    UUID winnerId, String winnerName, int totalEvents) {
        StringBuilder sb = new StringBuilder(1024);
        sb.append("{\"record\":\"META\"")
          .append(",\"gameId\":\"").append(gameUuid).append('"')
          .append(",\"startedAt\":\"").append(DateTimeFormatter.ISO_INSTANT.format(startedAt.truncatedTo(java.time.temporal.ChronoUnit.SECONDS))).append('"')
          .append(",\"endedAt\":\"").append(DateTimeFormatter.ISO_INSTANT.format(endedAt.truncatedTo(java.time.temporal.ChronoUnit.SECONDS))).append('"')
          .append(",\"winnerId\":");
        if (winnerId == null) sb.append("null"); else sb.append('"').append(winnerId).append('"');
        sb.append(",\"winnerName\":");
        if (winnerName == null) sb.append("\"Game is a draw\""); else { sb.append('"'); Json.escape(sb, winnerName); sb.append('"'); }
        sb.append(",\"totalEvents\":").append(totalEvents);
        sb.append(",\"players\":[");
        appendPlayerMeta(sb, idA, "PlayerA", startingLifeA, deckA);
        sb.append(',');
        appendPlayerMeta(sb, idB, "PlayerB", startingLifeB, deckB);
        sb.append(']');
        sb.append(",\"extras\":{")
          .append("\"batchIndex\":").append(opts.batchIndex)
          .append(",\"batchSeed\":").append(opts.seed)
          .append(",\"gameSeed\":").append(gameSeed)
          .append(",\"skill\":").append(opts.skill)
          .append(",\"maxTurns\":").append(opts.maxTurns)
          .append(",\"deckAName\":\"").append(Json.escapeStr(deckAFile.getName())).append('"')
          .append(",\"deckBName\":\"").append(Json.escapeStr(deckBFile.getName())).append('"')
          .append('}');
        sb.append('}');
        return sb.toString();
    }

    private static void appendPlayerMeta(StringBuilder sb, UUID id, String name,
                                          int startingLife, Deck deck) {
        sb.append('{')
          .append("\"id\":\"").append(id).append('"')
          .append(",\"name\":\"").append(Json.escapeStr(name)).append('"')
          .append(",\"startingLife\":").append(startingLife)
          .append(",\"deck\":[");
        boolean first = true;
        if (deck.getMain() != null) {
            for (var entry : deck.getMain()) {
                int n = entry.getValue();
                String cardName = entry.getKey().getName();
                for (int i = 0; i < n; i++) {
                    if (!first) sb.append(',');
                    first = false;
                    sb.append('"');
                    Json.escape(sb, cardName);
                    sb.append('"');
                }
            }
        }
        sb.append("]}");
    }

    /* -------- options parsing ---------------------------------------- */

    private static final class Options {
        Path decksDir = Paths.get("rogue_dck");
        Path outputDir = Paths.get("batches");
        int count = 1;
        int batchIndex = 0;
        int skill = 3;
        int maxTurns = 50;
        long seed = System.currentTimeMillis();
        long gameTimeoutSec = 300;
        boolean gzip = true;

        static Options parse(String[] args) {
            Options o = new Options();
            for (int i = 0; i < args.length; i++) {
                String a = args[i];
                String v = (i + 1 < args.length) ? args[i + 1] : null;
                switch (a) {
                    case "--decks-dir":   o.decksDir = Paths.get(v); i++; break;
                    case "--output-dir":  o.outputDir = Paths.get(v); i++; break;
                    case "--count":       o.count = Integer.parseInt(v); i++; break;
                    case "--batch-index": o.batchIndex = Integer.parseInt(v); i++; break;
                    case "--skill":       o.skill = Integer.parseInt(v); i++; break;
                    case "--max-turns":   o.maxTurns = Integer.parseInt(v); i++; break;
                    case "--seed":        o.seed = Long.parseLong(v); i++; break;
                    case "--game-timeout-sec": o.gameTimeoutSec = Long.parseLong(v); i++; break;
                    case "--gzip":   o.gzip = true; break;
                    case "--no-gzip": o.gzip = false; break;
                    case "--help": case "-h":
                        System.out.println("Usage: BatchRogueSimulator [--decks-dir DIR] [--output-dir DIR] "
                                + "[--count N] [--batch-index I] [--skill K] [--max-turns N] "
                                + "[--seed N] [--game-timeout-sec N] [--gzip|--no-gzip]");
                        System.exit(0);
                    default:
                        throw new IllegalArgumentException("Unknown arg: " + a);
                }
            }
            return o;
        }
    }

    /* -------- replay state + listener -------------------------------- */

    /** Mutable per-game capture state — appended to from the game thread. */
    private static final class ReplayState {
        final Game game;
        final UUID gameId;
        final UUID idA, idB;
        final int maxTurns;
        final List<String> events = new ArrayList<>(2048);
        final Map<Integer, UUID> cardIds = new HashMap<>();
        final Map<Player, UUID> playerIds = new IdentityHashMap<>();
        final GameLog scratchLog = new GameLog();
        final GameLogFormatter formatter = new GameLogFormatter(scratchLog);
        int seq = 0;
        boolean playersBound = false;
        String winnerName = null;
        boolean gameStartEmitted = false;
        boolean gameEndEmitted = false;

        ReplayState(Game game, UUID gameId, UUID idA, UUID idB, int maxTurns) {
            this.game = game;
            this.gameId = gameId;
            this.idA = idA;
            this.idB = idB;
            this.maxTurns = maxTurns;
        }

        UUID idForCard(Card c) {
            return cardIds.computeIfAbsent(c.getId(), k -> UUID.randomUUID());
        }

        UUID idForPlayer(Player p) {
            if (!playersBound) {
                bindPlayerIds();
            }
            return playerIds.get(p);
        }

        private void bindPlayerIds() {
            // getRegisteredPlayers() includes both ingame and lost players;
            // getPlayers() drops players the moment they lose, which would
            // erase the loser from end-of-game snapshots.
            List<Player> ps = game.getRegisteredPlayers();
            if (ps.size() >= 2) {
                playerIds.put(ps.get(0), idA);
                playerIds.put(ps.get(1), idB);
                playersBound = true;
            }
        }
    }

    /** Subscribed to the game's EventBus; emits one JSONL line per event. */
    public static final class ReplayListener {
        private final ReplayState s;

        ReplayListener(ReplayState s) { this.s = s; }

        @Subscribe
        public void onEvent(GameEvent ev) {
            try {
                if (!s.gameStartEmitted) {
                    emit("GAME_START", null);
                    s.gameStartEmitted = true;
                }

                if (ev instanceof GameEventTurnBegan
                        && s.maxTurns > 0
                        && s.game.getPhaseHandler().getTurn() > s.maxTurns) {
                    s.game.setGameOver(GameEndReason.Draw);
                }

                if (ev instanceof GameEventPlayerPriority p) {
                    String desc = "PRIORITY " + (p.priority() != null ? p.priority().getName() : "?");
                    emit("PRIORITY", desc);
                    return;
                }
                if (ev instanceof GameEventSpellAbilityCast c) {
                    emit("STACK_PUSH", c.toString());
                    return;
                }
                if (ev instanceof GameEventSpellResolved r) {
                    String desc = r.stackDescription() != null ? r.stackDescription() : r.toString();
                    emit("STACK_RESOLVE", desc);
                    return;
                }
                if (ev instanceof GameEventGameOutcome o) {
                    s.winnerName = o.winningPlayerName();
                    String desc = o.outcomeStrings() == null || o.outcomeStrings().isEmpty()
                            ? "Game ended" : String.join("; ", o.outcomeStrings());
                    emit("GAME_END", desc);
                    s.gameEndEmitted = true;
                    return;
                }
                if (ev instanceof GameEventGameFinished) {
                    if (!s.gameEndEmitted) {
                        emit("GAME_END", "Game finished");
                        s.gameEndEmitted = true;
                    }
                    return;
                }

                // Fallback: treat as LOG if the formatter produces text.
                GameLogEntry le = ev.visit(s.formatter);
                if (le != null && le.message() != null && !le.message().isEmpty()) {
                    emit("LOG", le.message());
                }
            } catch (Throwable t) {
                // Don't let a snapshot error kill the game thread.
                System.err.println("[replay] event handler error: " + t);
            }
        }

        private void emit(String type, String description) {
            StringBuilder sb = new StringBuilder(512);
            sb.append("{\"record\":\"EVENT\"")
              .append(",\"gameId\":\"").append(s.gameId).append('"')
              .append(",\"seq\":").append(s.seq++)
              .append(",\"type\":\"").append(type).append('"')
              .append(",\"description\":");
            if (description == null) sb.append("null");
            else { sb.append('"'); Json.escape(sb, description); sb.append('"'); }
            sb.append(",\"snapshot\":");
            Snapshots.appendSnapshot(sb, s);
            sb.append(",\"triggerOrder\":null}");
            s.events.add(sb.toString());
        }
    }

    /* -------- snapshot rendering ------------------------------------- */

    private static final class Snapshots {
        static void appendSnapshot(StringBuilder sb, ReplayState s) {
            Game g = s.game;
            PhaseHandler ph = g.getPhaseHandler();
            PhaseType pt = ph.getPhase();
            Player active = ph.getPlayerTurn();
            Player priority = ph.getPriorityPlayer();

            sb.append('{');
            sb.append("\"turn\":").append(ph.getTurn());
            sb.append(",\"phase\":");
            appendPhaseGroup(sb, pt);
            sb.append(",\"step\":");
            appendStep(sb, pt);
            sb.append(",\"activePlayerId\":");
            appendIdOrNull(sb, s, active);
            sb.append(",\"priorityPlayerId\":");
            appendIdOrNull(sb, s, priority);

            sb.append(",\"players\":[");
            boolean first = true;
            for (Player p : g.getRegisteredPlayers()) {
                if (!first) sb.append(',');
                first = false;
                appendPlayerSnapshot(sb, s, p);
            }
            sb.append(']');

            sb.append(",\"battlefield\":[");
            first = true;
            for (Card c : g.getCardsIn(ZoneType.Battlefield)) {
                if (!first) sb.append(',');
                first = false;
                appendCardSnapshot(sb, s, c);
            }
            sb.append(']');

            sb.append(",\"stack\":[");
            MagicStack stack = g.getStack();
            first = true;
            if (stack != null) {
                for (SpellAbilityStackInstance si : stack) {
                    if (!first) sb.append(',');
                    first = false;
                    sb.append('{')
                      .append("\"description\":\"");
                    String desc = si.getStackDescription();
                    Json.escape(sb, desc != null ? desc : "");
                    sb.append('"').append('}');
                }
            }
            sb.append(']');

            sb.append(",\"playableActions\":[]");
            sb.append('}');
        }

        private static void appendIdOrNull(StringBuilder sb, ReplayState s, Player p) {
            UUID id = (p == null) ? null : s.idForPlayer(p);
            if (id == null) sb.append("null");
            else sb.append('"').append(id).append('"');
        }

        private static void appendPlayerSnapshot(StringBuilder sb, ReplayState s, Player p) {
            sb.append('{');
            sb.append("\"id\":\"").append(s.idForPlayer(p)).append('"');
            sb.append(",\"name\":\"").append(Json.escapeStr(p.getName())).append('"');
            sb.append(",\"life\":").append(p.getLife());
            sb.append(",\"librarySize\":").append(p.getZone(ZoneType.Library).size());
            int hSize = p.getZone(ZoneType.Hand).size();
            sb.append(",\"handSize\":").append(hSize);
            sb.append(",\"hand\":[");
            appendCardNames(sb, p.getCardsIn(ZoneType.Hand));
            sb.append(']');
            sb.append(",\"graveyard\":[");
            appendCardNames(sb, p.getCardsIn(ZoneType.Graveyard));
            sb.append(']');
            sb.append(",\"exile\":[");
            appendOwnedCardNames(sb, p);
            sb.append(']');
            sb.append(",\"manaPool\":\"\"");
            sb.append(",\"hasLost\":").append(p.hasLost());
            sb.append(",\"hasWon\":").append(p.hasWon());
            sb.append('}');
        }

        private static void appendCardNames(StringBuilder sb, Iterable<Card> cards) {
            boolean first = true;
            for (Card c : cards) {
                if (!first) sb.append(',');
                first = false;
                sb.append('"');
                Json.escape(sb, c.getName());
                sb.append('"');
            }
        }

        private static void appendOwnedCardNames(StringBuilder sb, Player owner) {
            // Player exile: cards in the Exile zone owned by this player.
            boolean first = true;
            for (Card c : owner.getGame().getCardsIn(ZoneType.Exile)) {
                if (c.getOwner() != owner) continue;
                if (!first) sb.append(',');
                first = false;
                sb.append('"');
                Json.escape(sb, c.getName());
                sb.append('"');
            }
        }

        private static void appendCardSnapshot(StringBuilder sb, ReplayState s, Card c) {
            sb.append('{');
            sb.append("\"id\":\"").append(s.idForCard(c)).append('"');
            sb.append(",\"name\":\"").append(Json.escapeStr(c.getName())).append('"');
            sb.append(",\"controllerId\":");
            Player ctrl = c.getController();
            if (ctrl == null) sb.append("null");
            else sb.append('"').append(s.idForPlayer(ctrl)).append('"');
            sb.append(",\"tapped\":").append(c.isTapped());
            sb.append(",\"summoningSickness\":").append(c.hasSickness());
            sb.append(",\"power\":").append(c.isCreature() ? c.getNetPower() : 0);
            sb.append(",\"toughness\":").append(c.isCreature() ? c.getNetToughness() : 0);
            sb.append(",\"damage\":").append(c.getDamage());
            sb.append(",\"attachedTo\":");
            Card att = c.getAttachedTo();
            if (att == null) sb.append("null");
            else sb.append('"').append(s.idForCard(att)).append('"');
            sb.append(",\"counters\":null");
            sb.append('}');
        }

        private static void appendPhaseGroup(StringBuilder sb, PhaseType pt) {
            String g;
            if (pt == null) g = null;
            else switch (pt) {
                case UNTAP: case UPKEEP: case DRAW: g = "BEGINNING"; break;
                case MAIN1: g = "PRECOMBAT_MAIN"; break;
                case COMBAT_BEGIN: case COMBAT_DECLARE_ATTACKERS:
                case COMBAT_DECLARE_BLOCKERS: case COMBAT_FIRST_STRIKE_DAMAGE:
                case COMBAT_DAMAGE: case COMBAT_END: g = "COMBAT"; break;
                case MAIN2: g = "POSTCOMBAT_MAIN"; break;
                case END_OF_TURN: case CLEANUP: g = "ENDING"; break;
                default: g = pt.name();
            }
            if (g == null) sb.append("null");
            else sb.append('"').append(g).append('"');
        }

        private static void appendStep(StringBuilder sb, PhaseType pt) {
            String step;
            if (pt == null) step = null;
            else switch (pt) {
                case UNTAP: step = "UNTAP"; break;
                case UPKEEP: step = "UPKEEP"; break;
                case DRAW: step = "DRAW"; break;
                case MAIN1: step = "PRECOMBAT_MAIN"; break;
                case COMBAT_BEGIN: step = "BEGIN_COMBAT"; break;
                case COMBAT_DECLARE_ATTACKERS: step = "DECLARE_ATTACKERS"; break;
                case COMBAT_DECLARE_BLOCKERS: step = "DECLARE_BLOCKERS"; break;
                case COMBAT_FIRST_STRIKE_DAMAGE: step = "FIRST_STRIKE_DAMAGE"; break;
                case COMBAT_DAMAGE: step = "COMBAT_DAMAGE"; break;
                case COMBAT_END: step = "END_COMBAT"; break;
                case MAIN2: step = "POSTCOMBAT_MAIN"; break;
                case END_OF_TURN: step = "END_OF_TURN"; break;
                case CLEANUP: step = "CLEANUP"; break;
                default: step = pt.name();
            }
            if (step == null) sb.append("null");
            else sb.append('"').append(step).append('"');
        }
    }

    /* -------- minimal JSON string escaping --------------------------- */

    private static final class Json {
        static String escapeStr(String s) {
            StringBuilder sb = new StringBuilder(s.length() + 8);
            escape(sb, s);
            return sb.toString();
        }
        static void escape(StringBuilder sb, String s) {
            if (s == null) return;
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '"': sb.append("\\\""); break;
                    case '\\': sb.append("\\\\"); break;
                    case '\b': sb.append("\\b"); break;
                    case '\f': sb.append("\\f"); break;
                    case '\n': sb.append("\\n"); break;
                    case '\r': sb.append("\\r"); break;
                    case '\t': sb.append("\\t"); break;
                    default:
                        if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                        else sb.append(c);
                }
            }
        }
    }

    private BatchRogueSimulator() {}
}
