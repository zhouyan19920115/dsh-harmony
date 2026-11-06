// 体检 + 修复 tools\ 下脚本的编码坑。
//
// **坑 1 —— .ps1 缺 UTF-8 BOM**: PowerShell 5.1 读 .ps1 时, 没有 BOM 就按系统 ANSI
// 代码页(中文机器=GBK)读, 文件里的中文变成乱码, 引号被吃掉, 报的是莫名其妙的
// "Unexpected token"。这个坑今天踩了三次, 每次都是「某个工具重写了 .ps1, BOM 顺手
// 没了」触发的。
//
// **坑 2 —— .cmd 必须是 CRLF 行尾**: cmd.exe 在 `chcp` 之后会**重新读取**批处理文件,
// 而它按字节算偏移, 纯 LF 的文件偏移会错位 —— 结果是 `chcp` 被读成 `cp`、`rem`
// 被当命令执行, 整个脚本报废。(文件里有中文时必现。)
//
// 所以这个脚本用 Node 写 —— Node 读文件从来不看 BOM, 自己也永远不需要 BOM ✓
//
// 用法:
//   node tools\fix-scripts-encoding.mjs          检查 + 修
//   node tools\fix-scripts-encoding.mjs --check  只检查, 不写(退出码 1 = 有问题)
import { readdirSync, readFileSync, writeFileSync, statSync } from 'node:fs';
import { join, extname } from 'node:path';

const toolsDir = new URL('.', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/u, '$1');
const checkOnly = process.argv.includes('--check');
const BOM = Buffer.from([0xef, 0xbb, 0xbf]);

/** Every .ps1 / .cmd under tools/ (recursively). */
function scripts(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      if (name === 'node_modules' || name.startsWith('.')) continue;
      out.push(...scripts(full));
      continue;
    }
    const ext = extname(name).toLowerCase();
    if (ext === '.ps1' || ext === '.cmd') out.push(full);
  }
  return out;
}

const files = scripts(toolsDir);
let fixed = 0;
let broken = 0;

for (const file of files) {
  const name = file.slice(toolsDir.length);
  const bytes = readFileSync(file);

  if (extname(file).toLowerCase() === '.cmd') {
    // The batch file must use CRLF. The encoding stays UTF-8 without BOM (cmd.exe chokes
    // on a BOM in a batch file) ✓
    const text = bytes.toString('utf8');
    const normalized = text.replace(/\r\n/gu, '\n').replace(/\n/gu, '\r\n');
    if (normalized !== text) {
      broken += 1;
      if (checkOnly) {
        console.log(`  [!] ${name}  不是 CRLF 行尾 —— cmd.exe 会解析错位`);
      } else {
        writeFileSync(file, Buffer.from(normalized, 'utf8'));
        fixed += 1;
        console.log(`  [✓] ${name}  已转成 CRLF 行尾`);
      }
    }

    // **A batch file must be pure ASCII.** cmd.exe re-reads the file after `chcp` and
    // computes the offset in bytes, so a single multibyte character makes it resume
    // reading in the middle of a line: half a command gets executed and you get
    // "'m' is not recognized". It happened here: the file had check marks in the
    // comments, and after an edit the cut landed on a different line ✓
    const after = readFileSync(file);
    const bad = [...after].filter((byte) => byte > 127).length;
    if (bad > 0) {
      broken += 1;
      if (checkOnly) {
        console.log(`  [!] ${name}  里有 ${bad} 个非 ASCII 字节 —— cmd.exe 会把某一行切坏`);
      } else {
        const ascii = Buffer.from(after.toString('utf8').replace(/[^\x00-\x7F]/gu, ''), 'utf8');
        writeFileSync(file, ascii);
        fixed += 1;
        console.log(`  [✓] ${name}  已去掉 ${bad} 个非 ASCII 字节(必须是纯 ASCII)`);
      }
    }
    continue;
  }

  const hasBom = bytes.length >= 3 && bytes[0] === BOM[0] && bytes[1] === BOM[1] && bytes[2] === BOM[2];
  // A .ps1 that contains Chinese MUST have the BOM: without it, PowerShell 5.1 reads it as
  // GBK and the Chinese breaks the syntax. A pure ASCII .ps1 does not care.
  const body = hasBom ? bytes.subarray(3) : bytes;
  const hasChinese = /[\u4e00-\u9fff]/u.test(body.toString('utf8'));

  // **Two BOMs**: some tool wrote the file by decoding it as UTF-8 (the BOM character
  // included) and encoding it again with a BOM ⇒ the file starts with EF BB BF EF BB BF.
  // PowerShell uses the first BOM as the encoding marker and then treats the second one as
  // a character in the code ⇒ the Chinese breaks and the script dies with a parse error ✓
  if (hasBom && body.length >= 3 && body[0] === BOM[0] && body[1] === BOM[1] && body[2] === BOM[2]) {
    broken += 1;
    if (checkOnly) {
      console.log(`  [!] ${name}  开头有两个 BOM —— PowerShell 会把第二个当成代码, 中文全乱`);
      continue;
    }
    writeFileSync(file, Buffer.concat([BOM, body.subarray(3)]));
    fixed += 1;
    console.log(`  [✓] ${name}  去掉多余的第二个 BOM`);
    continue;
  }

  if (hasBom) {
    if (!hasChinese) console.log(`  [i] ${name}  (纯 ASCII, BOM 留着也无妨)`);
    continue;
  }
  if (!hasChinese) {
    console.log(`  [i] ${name}  (纯 ASCII, 不需要 BOM)`);
    continue;
  }
  broken += 1;
  if (checkOnly) {
    console.log(`  [!] ${name}  缺 UTF-8 BOM, 里面有中文 —— PowerShell 5.1 会读成乱码`);
    continue;
  }
  writeFileSync(file, Buffer.concat([BOM, body]));
  fixed += 1;
  console.log(`  [✓] ${name}  已补上 UTF-8 BOM`);
}

if (broken === 0) {
  console.log(`\n  ${files.length} 个脚本全部正常 ✓`);
} else if (checkOnly) {
  console.log(`\n  [!] ${broken} 个脚本有编码问题 —— 跑 node tools\\fix-scripts-encoding.mjs 修掉`);
  process.exitCode = 1;
} else {
  console.log(`\n  ${files.length} 个脚本, 修了 ${fixed} 个 ✓`);
}
