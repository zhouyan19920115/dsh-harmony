#!/usr/bin/env node
/**
 * 解析 uitest dumpLayout 出来的 JSON, 打印可交互元素, 以及按文本查坐标。
 * 用法:
 *   node tools/ui.js                 # 列出所有元素
 *   node tools/ui.js 桌面端地址       # 查找包含该文本的元素, 输出 "type text x y"
 */
import { readFileSync } from 'node:fs';

const file = process.argv[2] ?? 'tools/l2.json';
const filter = process.argv[3];
const raw = readFileSync(file, 'utf8');
const j = JSON.parse(raw);

const out = [];
(function walk(n) {
  if (!n) return;
  const a = n.attributes ?? {};
  if (a.text || a.type === 'TextInput' || a.type === 'Button' || a.type === 'TextArea') {
    const m = /\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]/.exec(a.bounds ?? '');
    const x = m ? Math.round((+m[1] + +m[3]) / 2) : 0;
    const y = m ? Math.round((+m[2] + +m[4]) / 2) : 0;
    const right = m ? +m[3] : 0;
    const bottom = m ? +m[4] : 0;
    out.push({ type: a.type, text: a.text, x, y, right, bottom });
  }
  (n.children ?? []).forEach(walk);
})(j);

if (filter) {
  const hits = out.filter((e) => (e.text ?? '').includes(filter));
  for (const h of hits) console.log(`${h.type}\t${h.text}\t${h.x}\t${h.y}\t${h.right}\t${h.bottom}`);
} else {
  for (const e of out) console.log(`${e.type}\t${e.text}\t${e.x}\t${e.y}\t${e.right}\t${e.bottom}`);
}
