# React Native Migration — MVP + Honest Assessment

---

## Honest Take: Is This a Good Idea?

**Short answer: No. It's a half-measure that solves the wrong problem.**

### Why people think RN makes sense for Glaze

| Argument | Reality |
|----------|---------|
| "Same language — reuse business logic!" | You can't reuse it as-is. RN has no IndexedDB, no Web Worker, no `crypto.subtle`, no Canvas, no `FileReader`, no `DataView`, no `ArrayBuffer` worth speaking of. Every service file needs a rewrite. |
| "JS ecosystem = faster dev" | The ecosystem is npm packages that assume `window`, `document`, or Node APIs. Most won't work in RN without polyfills. You spend more time polyfilling than building. |
| "Community is huge" | True for CRUD apps and e-commerce. For binary parsing, streaming SSE, crypto, and prompt engines — the community is thin. |
| "Can share code with current Glaze" | You can share pure logic (macro engine, regex). But 70% of Glaze's code touches Web APIs or platform-specific code. That 70% rewrites from scratch. |

### The real problem RN doesn't solve

Glaze is a **Capacitor app running in a WebView**. The pain points are:

1. **iOS WKWebView bugs** — keyboard, memory, background execution
2. **No real threads** — Web Workers are fake on mobile (same process, shared memory limits)
3. **IndexedDB reliability** — especially on iOS with storage pressure
4. **Canvas/File API limitations** — PNG manipulation is painful
5. **Background execution** — iOS kills WebView-based apps

RN gives you **native UI** but keeps you in **JS runtime**. The JS runtime is exactly where the problems are:

| Pain Point | Capacitor | React Native | Flutter |
|-----------|-----------|-------------|---------|
| iOS keyboard bugs | Broken | Fixed (native UI) | Fixed (native UI) |
| Real threads | No (Worker is fake) | **No (JSC/Hermes is single-threaded)** | Yes (Isolates) |
| Binary data (PNG, LMDB) | Polyfill hell | **Polyfill hell** | Native (ByteData, Uint8List) |
| Crypto (AES-GCM) | `crypto.subtle` | **Needs native module** | `package:encrypt` |
| IndexedDB | Built-in | **Replace entirely** | Isar (native) |
| SSE streaming | `fetch()` + polyfill | **Needs polyfill or native** | Dio (native) |
| Canvas (PNG export) | Canvas API | **No canvas** | `package:image` |
| Background execution | iOS kills WebView | **iOS kills JS too** | Native background isolate |
| ZIP handling | JSZip (slow) | JSZip + buffer polyfills (slower) | `archive` package (native) |

### The specific landmines

**1. ArrayBuffer / Uint8Array in RN**

RN's JSC/Hermes doesn't have full `ArrayBuffer` support. The `buffer` package on npm provides a polyfill, but it's **10-100x slower** than native. For Tavo's LMDB parser (857 lines of binary walking), this means a 5-second import becomes 50+ seconds.

**2. No Web Worker**

`generationWorker.js` (999 lines) runs the prompt builder off the main thread. RN has no equivalent. Options:
- `react-native-workers` — abandoned, doesn't work with New Architecture
- Move to a native module (Swift/Kotlin) — defeats the "same language" purpose
- Run on JS thread — UI freezes during prompt building
- `worker_threads` via Hermes — experimental, not production-ready

**3. SSE / streaming**

Current Glaze uses `fetch()` with `ReadableStream`. RN's `fetch` doesn't support streaming. You need:
- `react-native-sse` (unmaintained, last update 2023)
- Or a native module
- Or EventSource polyfill (doesn't support POST bodies)

This is **the core of the app** — streaming LLM responses. If streaming is janky, the app is unusable.

**4. File system**

`react-native-fs` is the standard. It's:
- Slow for large files
- No streaming reads
- Inconsistent behavior across platforms
- Community version (`react-native-fs`) is semi-maintained

For image-heavy operations (gallery, avatars, PNG export), this is a bottleneck.

**5. crypto.subtle → native bridge**

AES-256-GCM encryption in sync requires `crypto.subtle`. RN has no equivalent. You need:
- `react-native-quick-crypto` (best option, but still a bridge call)
- Or `expo-crypto` (limited — no AES-GCM)

Every encrypt/decrypt crosses the JS→native bridge. For sync (potentially hundreds of entities), this adds up.

**6. The New Architecture tax**

RN's New Architecture (Fabric + TurboModules) is required for good performance, but:
- Many libraries don't support it yet
- Migration guides are incomplete
- You'll hit edge cases that nobody has documented

### When RN *would* make sense

If Glaze were a typical app — list of items, forms, API calls, simple storage — RN would be fine. But Glaze is:
- **Binary-parser-heavy** (PNG chunks, LMDB, ZIP)
- **Streaming-heavy** (SSE, incremental text)
- **Crypto-heavy** (AES-256-GCM, SHA-256)
- **Compute-heavy** (prompt building, token estimation, regex matching)
- **Thread-sensitive** (prompt builder must not block UI)

These are the exact things RN is worst at.

### Bottom line

| | Capacitor (now) | React Native | Flutter |
|--|-----------------|-------------|---------|
| Effort to migrate | — | ~70% rewrite | ~80% rewrite |
| Solves WebView issues | No | Partially | **Yes** |
| Real threading | No | No | **Yes** |
| Binary data performance | Bad | Bad | **Good** |
| Streaming SSE | Works (polyfill) | Broken without native module | **Native** |
| Crypto | `crypto.subtle` | Native bridge (slow) | **Native package** |
| Long-term maintainability | Declining | Medium | **Good** |
| Desktop support | PWA only | No (needs Electron) | **Built-in** |

**RN is the worst of both worlds for Glaze**: you do 70% of a rewrite but keep the JS runtime problems. Either stay on Capacitor and patch, or go to Flutter and actually fix the architecture.

---

## MVP Plan (if you still want to try it)

Despite everything above, here's a minimal 10-day spike to validate RN viability.

### Goal

Prove or disprove: can RN stream an LLM response without stuttering, parse a PNG character card, and save a chat to local storage?

### Day 1–2: Scaffold

```bash
npx create-expo-app glaze-rn --template blank-typescript
cd glaze-rn
npx expo install expo-router expo-file-system expo-secure-store
npx expo install @react-navigation/native @react-navigation/native-stack
npx expo install react-native-mmkv  # replaces IndexedDB
```

**DB: MMKV** (not AsyncStorage — too slow). MMKV is synchronous, fast, and works everywhere. For relational queries, use `react-native-sqlite-storage` or `@op-engineering/op-sqlite`.

**State: Zustand** (simpler than Redux, works well with RN).

**Navigation: Expo Router** (file-based, like Next.js).

### Day 3–4: Data layer

```typescript
// src/db/schema.ts
interface Character {
  id: string;
  name: string;
  avatar: string | null;  // base64 or file:// path
  description: string;
  personality: string;
  scenario: string;
  firstMes: string;
  mesExample: string;
  systemPrompt: string;
  tags: string[];
}

interface ChatMessage {
  id: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: number;
  swipes: string[];
  swipeId: number;
}

interface ChatSession {
  id: string;
  characterId: string;
  messages: ChatMessage[];
}

// src/db/repository.ts
import { MMKV } from 'react-native-mmkv';

const storage = new MMKV();

function saveCharacters(chars: Character[]) {
  storage.set('characters', JSON.stringify(chars));
}

function loadCharacters(): Character[] {
  return JSON.parse(storage.getString('characters') || '[]');
}
```

**Pitfall**: MMKV has a ~1MB practical limit per key. For large chat histories, store sessions separately:
```typescript
storage.set(`chat_${sessionId}`, JSON.stringify(messages));
```

### Day 5–6: PNG import + streaming

```typescript
// src/services/pngParser.ts
import { Buffer } from 'buffer';  // polyfill needed!

export function parsePngCharacter(bytes: Buffer): object | null {
  // 1. Validate PNG signature
  // 2. Walk chunks, find tEXt with keyword 'chara'
  // 3. base64 decode → JSON.parse
  // ⚠️ This requires 'buffer' polyfill — add to metro.config.js
}
```

**Critical polyfill setup** (this alone takes half a day):
```javascript
// metro.config.js
const { getDefaultConfig } = require('expo/metro-config');
const config = getDefaultConfig(__dirname);
config.resolver.extraNodeModules = {
  buffer: require.resolve('buffer'),
  stream: require.resolve('readable-stream'),
  crypto: require.resolve('react-native-quick-crypto'),
};
```

**SSE streaming** — this is the go/no-go test:
```typescript
// src/services/sseClient.ts
// Option A: react-native-sse (unmaintained)
// Option B: custom native module
// Option C: fetch polyfill with streaming

// Most reliable: use XMLHttpRequest with chunked response
export function streamChatCompletion(config: ApiConfig, messages: Message[]): EventTarget {
  const xhr = new XMLHttpRequest();
  // ... set up chunked response handling
  // ⚠️ RN's XHR doesn't support true streaming on all platforms
  // This is the #1 risk — if it doesn't work, the whole approach is dead
}
```

### Day 7–8: Chat UI

```typescript
// src/screens/ChatScreen.tsx
import { FlatList } from 'react-native';

function ChatScreen({ characterId }: { characterId: string }) {
  const messages = useChatStore(state => state.messages);
  const streamingText = useChatStore(state => state.streamingText);
  const isGenerating = useChatStore(state => state.isGenerating);

  return (
    <View style={styles.container}>
      <FlatList
        data={[...messages, ...(streamingText ? [{ id: 'streaming', role: 'assistant', content: streamingText }] : [])]}
        keyExtractor={item => item.id}
        renderItem={({ item }) => <MessageBubble message={item} />}
        inverted
      />
      <InputBar onSend={handleSend} disabled={isGenerating} />
    </View>
  );
}
```

### Day 9: API settings

Simple form: endpoint, API key, model. Stored in MMKV.

### Day 10: Go/No-Go

Test on a **real device** (not simulator):
- [ ] Stream a response — does it arrive token-by-token or all-at-once?
- [ ] Does the UI stay responsive during streaming?
- [ ] Import a PNG character card — does the buffer polyfill work without crashing?
- [ ] Save 100+ messages — is MMKV fast enough?
- [ ] Does it work on **iOS** specifically? (Android is easier for RN)

**If any of these fail, stop. RN is not viable for Glaze.**

---

## Summary of Pitfalls

| Pitfall | Severity | Workaround | Cost |
|---------|----------|------------|------|
| No SSE streaming | **Killer** | Native module | 3-5 days + ongoing maintenance |
| No Web Workers | **Killer** | Native module or accept UI freezes | 5-10 days |
| ArrayBuffer polyfills | High | `buffer` npm package | Slow, crashes on large data |
| No `crypto.subtle` | Medium | `react-native-quick-crypto` | Bridge overhead per call |
| No Canvas | Medium | `react-native-image-manipulator` (limited) | Can't do PNG tEXt chunk export |
| MMKV size limits | Medium | Split into per-session keys | Manageable |
| File system inconsistencies | Medium | `expo-file-system` + `react-native-fs` | Fragmented API |
| New Architecture compat | Low-Medium | Stick to Old Arch for now | Future tech debt |
| Expo vs Bare tradeoffs | Medium | Expo for speed, Bare for native modules | Can't have both easily |
| Bridge overhead for binary | High | Minimize crossings, batch operations | Architecture constraint |

---

## Verdict

**If you're going to rewrite 70% of the app anyway, rewrite it in a language that solves the actual problems.** Dart with Flutter gives you real threads, native binary I/O, native crypto, native streaming, and desktop support. RN gives you native UI but keeps every JS runtime problem you already have.

The only scenario where RN makes sense: you have a team that only knows JS and can't learn Dart. But for a solo dev or small team, the learning curve of Dart is 2-3 days — far cheaper than the months you'll spend fighting RN's platform gaps.
