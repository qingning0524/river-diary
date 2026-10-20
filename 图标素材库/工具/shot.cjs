const fs = require('fs');
const { pathToFileURL } = require('url');
const { chromium } = require('playwright');
(async () => {
  const specs = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const browser = await chromium.launch({ headless: true, executablePath: process.env.RIVER_ICON_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' });
  for (const s of specs) {
    const page = await browser.newPage({ viewport: { width: s.width, height: s.height }, deviceScaleFactor: 2 });
    await page.goto(pathToFileURL(s.url).href);
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: s.out, fullPage: true, animations: 'disabled' });
    await page.close();
    console.log('SHOT', s.out);
  }
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
