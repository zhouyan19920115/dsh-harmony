/**
 * 时间格式化工具。
 */

/** 把 epoch 毫秒格式化成 "今天 10:24" / "10-21 08:03" */
export function formatTime(ts: number): string {
  if (ts <= 0) {
    return '';
  }
  const d = new Date(ts);
  const now = new Date();
  const hh: string = `${d.getHours()}`.padStart(2, '0');
  const mm: string = `${d.getMinutes()}`.padStart(2, '0');
  if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()) {
    return `今天 ${hh}:${mm}`;
  }
  const mo: string = `${d.getMonth() + 1}`.padStart(2, '0');
  const dd: string = `${d.getDate()}`.padStart(2, '0');
  return `${mo}-${dd} ${hh}:${mm}`;
}

/** 相对时间, 例如 "3 分钟前" */
export function formatRelative(ts: number): string {
  if (ts <= 0) {
    return '';
  }
  const diff = Date.now() - ts;
  if (diff < 60_000) {
    return '刚刚';
  }
  if (diff < 3_600_000) {
    return `${Math.floor(diff / 60_000)} 分钟前`;
  }
  if (diff < 86_400_000) {
    return `${Math.floor(diff / 3_600_000)} 小时前`;
  }
  return `${Math.floor(diff / 86_400_000)} 天前`;
}
