import Foundation

/// The page a reviewer sees on their phone. Everything from the sermon is passed as JSON and
/// drawn with textContent, so nothing in a title or caption can run as code.
enum ReviewPage {
    static func html(_ r: ReviewRequest) -> String {
        let base = "/r/" + r.token
        let items: [[String: Any]] = r.items.map { it in
            var d: [String: Any] = ["id": it.id.uuidString, "kind": it.kind.rawValue, "title": it.title,
                                    "caption": it.caption ?? "", "decision": it.decision.rawValue,
                                    "note": it.note, "by": it.by]
            d["images"] = it.images.map { base + "/img/" + $0.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/") }
            func v(_ i: Int) -> String {
                let ext = URL(fileURLWithPath: r.videos[i]).pathExtension.lowercased()
                return base + "/v/\(i)." + (ext.isEmpty ? "mp4" : ext)
            }
            if let f = it.finished, r.videos.indices.contains(f) { d["video"] = v(f) }
            d["spans"] = it.spans.filter { r.videos.indices.contains($0.file) }.map { ["v": v($0.file), "s": $0.start, "e": $0.end] }
            return d
        }
        let payload: [String: Any] = ["title": r.title, "base": base, "items": items]
        let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // Keep the JSON from closing its script tag
        let safe = json.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
        return template.replacingOccurrences(of: "%%DATA%%", with: safe)
    }

    private static let template = #"""
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex">
<title>Review · AutoClip</title>
<style>
:root{--bg:#141517;--card:#1E1F22;--line:rgba(255,255,255,.09);--ink:#F1E9DC;--muted:rgba(241,233,220,.66);--sand:#D9C3A0;--good:#A3AE6E;--warn:#E3A15F;--act:#B4532F}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 -apple-system,system-ui,sans-serif;-webkit-text-size-adjust:100%}
header{padding:28px 18px 8px;max-width:640px;margin:0 auto}
.eyebrow{color:var(--sand);font-size:12px;font-weight:600;letter-spacing:.16em;text-transform:uppercase}
h1{font:500 28px/1.15 ui-serif,Georgia,serif;margin:6px 0 4px}
.sub{color:var(--muted);font-size:14px}
.who{display:flex;gap:8px;align-items:center;margin:16px 0 4px}
.who input{flex:1;background:var(--card);border:1px solid var(--line);color:var(--ink);border-radius:10px;padding:11px 12px;font-size:16px}
main{max-width:640px;margin:0 auto;padding:6px 12px 60px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;margin:14px 0;overflow:hidden}
.card.approved{border-color:rgba(163,174,110,.55)}
.card.changes{border-color:rgba(227,161,95,.55)}
.top{display:flex;justify-content:space-between;align-items:center;gap:10px;padding:14px 16px 10px}
.kind{color:var(--sand);font-size:11.5px;font-weight:600;letter-spacing:.12em;text-transform:uppercase}
.ttl{font-weight:600;font-size:16px;margin-top:2px}
.badge{font-size:12.5px;font-weight:600;padding:5px 10px;border-radius:99px;white-space:nowrap;background:rgba(255,255,255,.07);color:var(--muted)}
.badge.approved{background:rgba(163,174,110,.18);color:var(--good)}
.badge.changes{background:rgba(227,161,95,.18);color:var(--warn)}
video{display:block;width:100%;max-height:72vh;background:#000}
.strip{display:flex;overflow-x:auto;scroll-snap-type:x mandatory;gap:8px;padding:0 16px 4px}
.strip img{scroll-snap-align:center;flex:0 0 82%;max-width:82%;border-radius:8px;display:block}
.strip.one img{flex-basis:100%;max-width:100%}
.hint{color:var(--muted);font-size:12.5px;padding:8px 16px 0}
details{padding:8px 16px 0;color:var(--muted);font-size:14px}
details summary{cursor:pointer;color:var(--ink);font-size:14px}
details p{white-space:pre-wrap;margin:8px 0 0}
.acts{display:flex;gap:10px;padding:14px 16px 16px}
button{flex:1;border:0;border-radius:12px;padding:13px 10px;font-size:16px;font-weight:600;font-family:inherit}
.yes{background:var(--good);color:#141517}
.no{background:rgba(255,255,255,.08);color:var(--ink)}
.send{background:var(--warn);color:#141517}
textarea{display:block;width:calc(100% - 32px);margin:0 16px;min-height:84px;background:#141517;border:1px solid var(--line);color:var(--ink);border-radius:10px;padding:10px;font:16px -apple-system,system-ui}
.note{color:var(--warn);font-size:14px;padding:0 16px 12px;white-space:pre-wrap}
.done{color:var(--muted);font-size:13px;padding:0 16px 14px}
.err{color:var(--warn);font-size:13px;padding:0 16px 12px}
footer{color:var(--muted);text-align:center;font-size:12.5px;padding:10px 20px 40px}
</style></head>
<body>
<header>
  <div class="eyebrow">For your approval</div>
  <h1 id="title"></h1>
  <div class="sub" id="sum"></div>
  <div class="who"><input id="name" placeholder="Your name" autocomplete="name" maxlength="80"></div>
</header>
<main id="list"></main>
<footer>Sent from AutoClip. Your answers go straight back to the Mac that sent this.</footer>
<script type="application/json" id="data">%%DATA%%</script>
<script>
const D = JSON.parse(document.getElementById('data').textContent);
const $ = (t, c, txt) => { const e = document.createElement(t); if (c) e.className = c; if (txt != null) e.textContent = txt; return e; };
const nameBox = document.getElementById('name');
try { nameBox.value = localStorage.getItem('ac_name') || ''; } catch (e) {}
nameBox.addEventListener('change', () => { try { localStorage.setItem('ac_name', nameBox.value.trim()); } catch (e) {} });
document.getElementById('title').textContent = D.title;
const kinds = { clip: 'Clip', carousel: 'Carousel', post: 'Post' };

function summary() {
  const a = D.items.filter(i => i.decision === 'approved').length, c = D.items.filter(i => i.decision === 'changes').length;
  const w = D.items.length - a - c;
  document.getElementById('sum').textContent = `${D.items.length} to look at · ${a} approved` + (c ? ` · ${c} with changes` : '') + (w && (a || c) ? ` · ${w} left` : '');
}

function player(it) {
  if (it.video) { const v = $('video'); v.controls = true; v.playsInline = true; v.preload = 'metadata'; v.src = it.video; return [v]; }
  if (!it.spans.length) return [];
  const v = $('video'); v.controls = true; v.playsInline = true; v.preload = 'metadata';
  let k = 0;
  const go = (n, play) => {
    k = n; const s = it.spans[k];
    const seek = () => { v.currentTime = s.s; if (play) v.play().catch(() => {}); };
    if (v.dataset.src !== s.v) { v.dataset.src = s.v; v.src = s.v + '#t=' + s.s; v.addEventListener('loadedmetadata', seek, { once: true }); }
    else seek();
  };
  v.addEventListener('timeupdate', () => {
    const s = it.spans[k];
    if (v.currentTime >= s.e) { if (k + 1 < it.spans.length) go(k + 1, true); else { v.pause(); go(0, false); } }
    else if (v.currentTime < s.s - 0.5) v.currentTime = s.s;
  });
  go(0, false);
  const hint = $('div', 'hint', 'Preview without captions. It plays the moments the clip is made from.');
  return [v, hint];
}

function draw(it) {
  const card = $('div', 'card ' + (it.decision !== 'pending' ? it.decision : ''));
  const top = $('div', 'top'); const left = $('div');
  left.append($('div', 'kind', kinds[it.kind] || ''), $('div', 'ttl', it.title));
  const badge = $('span', 'badge ' + it.decision, it.decision === 'approved' ? 'Approved' : it.decision === 'changes' ? 'Changes asked' : 'Waiting');
  top.append(left, badge); card.append(top);
  if (it.kind === 'clip') card.append(...player(it));
  if (it.images.length) {
    const s = $('div', 'strip' + (it.images.length === 1 ? ' one' : ''));
    it.images.forEach(src => { const im = $('img'); im.loading = 'lazy'; im.src = src; im.alt = it.title; s.append(im); });
    card.append(s);
    if (it.images.length > 1) card.append($('div', 'hint', `Swipe for all ${it.images.length} slides.`));
  }
  if (it.caption) { const d = $('details'); d.append($('summary', null, 'Caption'), $('p', null, it.caption)); card.append(d); }
  if (it.decision === 'changes' && it.note) card.append($('div', 'note', '“' + it.note + '”' + (it.by ? ' — ' + it.by : '')));
  if (it.decision === 'approved' && it.by) card.append($('div', 'done', 'Approved by ' + it.by));
  const acts = $('div', 'acts');
  const yes = $('button', 'yes', it.decision === 'approved' ? 'Approved ✓' : 'Approve');
  const no = $('button', 'no', 'Ask for changes');
  acts.append(yes, no); card.append(acts);
  const err = $('div', 'err'); err.hidden = true; card.append(err);
  yes.onclick = () => answer(it, 'approved', '', card, err);
  no.onclick = () => {
    if (card.querySelector('textarea')) return;
    const t = $('textarea'); t.placeholder = 'What should change?'; t.value = it.decision === 'changes' ? it.note : '';
    const send = $('button', 'send', 'Send');
    const row = $('div', 'acts'); row.append(send);
    card.insertBefore(t, acts); card.insertBefore(row, acts); acts.hidden = true; t.focus();
    send.onclick = () => answer(it, 'changes', t.value.trim(), card, err);
  };
  return card;
}

async function answer(it, decision, note, card, err) {
  const by = nameBox.value.trim();
  try { localStorage.setItem('ac_name', by); } catch (e) {}
  try {
    const r = await fetch(D.base + '/answer', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ item: it.id, decision, note, by }) });
    if (!r.ok) throw new Error();
    it.decision = decision; it.note = note; it.by = by;
    card.replaceWith(draw(it)); summary();
  } catch (e) {
    err.hidden = false;
    err.textContent = "Couldn't send that. Check you're on the same Wi-Fi as the Mac and AutoClip is open, then try again.";
  }
}

const list = document.getElementById('list');
D.items.forEach(it => list.append(draw(it)));
summary();
</script>
</body></html>
"""#
}
