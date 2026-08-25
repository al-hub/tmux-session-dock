let frame = 0;

process.stdout.write('codex working');
setInterval(() => {
  process.stdout.write(`\r◌ codex working ${String(frame++).padStart(4, '0')}`);
}, 100);
