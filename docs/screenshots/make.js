#!/usr/bin/env node
/*
 * Скриншоты для README: WebUI в Chromium с заглушкой ksu.exec (как в
 * tests/webui), по три экрана в светлой и тёмной теме. Кадры складываются в
 * docs/screenshots/<тема>-<n>.png, склейка — docs/screenshots/compose.py.
 *   NODE_PATH=$(npm root -g) node docs/screenshots/make.js
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const REPO = path.resolve(__dirname, '..', '..');
const INDEX = 'file:///' + path.join(REPO, 'webroot', 'index.html');
const OUT = process.env.SHOTS_DIR || path.join(REPO, 'docs', 'screenshots', 'raw');
fs.mkdirSync(OUT, { recursive: true });

const STATUS = {
  running: true, pid: '4710', uptime: 15441, strategy: 'alt13', version: 'v2.0.2', mode: 'auto',
  pkt_limit_out: 15, pkt_limit_in: 15, block_quic: 0, app_mode: 'off', autostart: 1, watchdog: 1, ipv6: 1,
  log_level: 0, qdrop: 0, queue: 300, app_uids: 0, dns_available: 1, dns_enabled: 1, home_wifi: 1, net_strategy: 1,
  counts: { user: 385, auto: 31, exclude: 255, ipset: 28418, ipset_exclude: 637, apps: 0 },
};
const DNS = ['#status', 'enabled=1', 'default=net', 'service=running', 'standalone=0', 'proxy=running', 'rules=on',
  'ipv6=redirect', 'private=off', 'private_host=', 'net_dns=192.168.1.1', 'hits=18342', 'error=',
  'max_profiles=32', 'max_servers=8', 'max_domains=1000',
  '#profile ai', 'NAME=ИИ-сервисы', 'DESC=ChatGPT, Gemini, Claude', 'ENABLED=1',
  'SERVER=https://dns.comss.one/dns-query', 'DOMAIN=chatgpt.com', 'DOMAIN=openai.com', 'DOMAIN=gemini.google.com', 'DOMAIN=claude.ai',
  '#profile xbox', 'NAME=XBox DNS', 'DESC=Игры и сервисы Microsoft', 'ENABLED=1',
  'SERVER=https://xbox-dns.ru/dns-query', 'SERVER=tls://xbox-dns.ru', 'DOMAIN=xbox.com', 'DOMAIN=xboxlive.com',
  '#profile geo', 'NAME=GeoHide', 'DESC=Сервисы с геоблокировкой', 'ENABLED=0',
  'SERVER=https://dns.geohide.ru:444/dns-query', 'DOMAIN=spotify.com'].join('\n');
const HOSTS = ['#status', 'enabled=1', 'mounted=1', 'differs=0', 'conflicts=', 'bypass=199', 'bypass_preset=malw',
  'blocked=74215', 'block_custom=12', 'imported=', 'dir=/data/adb/nfqws2/hosts',
  '#preset adaway', 'NAME=AdAway', 'DESC=Блокировка рекламы и трекеров (список AdAway)', 'BLOCK=1', 'ENABLED=1', 'COUNT=6540',
  '#preset adguard', 'NAME=AdGuard DNS filter', 'DESC=Реклама и трекеры, большой список (~180 тыс. доменов)', 'BLOCK=1', 'ENABLED=0',
  '#preset geohide', 'NAME=GeoHide', 'DESC=Доступ', 'BYPASS=1', 'ENABLED=0',
  '#preset malw', 'NAME=dns.malw.link', 'DESC=Доступ', 'BLOCK_DESC=Рекламные и мусорные домены из файла dns.malw.link',
  'BYPASS=1', 'BLOCK=1', 'ENABLED=1', 'COUNT=26578'].join('\n');
const DC = 'MODE\tauto\nLIST\tuser.list\thost\tinstagram.com\nIP\t157.240.205.174\nR\t1\tok 184\nR\t2\tok 171\nR\t3\tok 190\ndone';
const LIST = ['# Домены для обхода', 'youtube.com', 'googlevideo.com', 'ytimg.com', 'youtu.be', 'instagram.com',
  'cdninstagram.com', 'facebook.com', 'fbcdn.net', 'x.com', 'twimg.com', 'discord.com', 'discord.gg',
  'discordapp.com', 'discordapp.net', 'linkedin.com', 'rutracker.org', 'medium.com', 'soundcloud.com',
  'youtube-nocookie.com', 'yt3.ggpht.com', 'i.ytimg.com', 'music.youtube.com', 'notion.so', 'chatgpt.com'].join('\n');

const STUB = `
window.ksu = { exec: function(cmd, opts, cb){
  var id = typeof cb === 'string' ? cb : opts, out = 'OK';
  if (cmd.indexOf('json-status') >= 0) out = ${JSON.stringify(JSON.stringify(STATUS))};
  else if (cmd.indexOf('list-strategies') >= 0) out = 'default\\nalt\\nalt13\\nfake_tls_auto\\nMartinBacker';
  else if (cmd.indexOf('get-strategy') >= 0) out = 'alt13';
  else if (cmd.indexOf("'dns-state'") >= 0) out = ${JSON.stringify(DNS)};
  else if (cmd.indexOf("'hosts-state'") >= 0) out = ${JSON.stringify(HOSTS)};
  else if (cmd.indexOf('domain-check') >= 0) out = ${JSON.stringify(DC)};
  else if (cmd.indexOf('get-list') >= 0) out = ${JSON.stringify(LIST)};
  else if (cmd.indexOf('changelog') >= 0) out = '';
  setTimeout(function(){ if (window[id]) window[id](0, out, ''); }, 0);
  return 'job';
}};
try { localStorage.setItem('nfqws_seen_version', 'v2.0.2'); } catch(e) {}
`;

const SCREENS = {
  light: [
    async p => { await p.evaluate(() => navigate('control')); },
    async p => { await p.evaluate(() => navigate('settings')); await p.waitForTimeout(500); await p.evaluate(() => navigate('dns')); },
    async p => { await p.evaluate(() => navigate('settings')); await p.waitForTimeout(500); await p.evaluate(() => navigate('hosts')); },
  ],
  dark: [
    async p => {
      await p.evaluate(() => navigate('settings')); await p.waitForTimeout(500);
      await p.evaluate(() => navigate('test')); await p.waitForTimeout(700);
      await p.click('#test-tabs .seg[data-tab="domain"]');
      await p.fill('#dc-q', 'instagram.com'); await p.click('#dc-go');
    },
    async p => {
      await p.evaluate(() => navigate('lists')); await p.waitForTimeout(500);
      await p.evaluate(() => openSlideEditor('list', 'user')); await p.waitForTimeout(900);
      await p.evaluate(() => toggleFind(true)); await p.fill('#find-q', 'youtube'); await p.press('#find-q', 'Enter');
    },
    async p => { await p.evaluate(() => navigate('settings')); },
  ],
};

(async () => {
  const browser = await chromium.launch();
  for (const mode of Object.keys(SCREENS)) {
    for (let i = 0; i < SCREENS[mode].length; i++) {
      const ctx = await browser.newContext({ viewport: { width: 400, height: 840 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
      await ctx.addInitScript(`try{localStorage.setItem('m3_mode','${mode}');}catch(e){}`);
      await ctx.addInitScript(STUB);
      const page = await ctx.newPage();
      page.on('pageerror', e => process.stderr.write(mode + i + ': ' + e.message + '\n'));
      await page.goto(INDEX, { waitUntil: 'load' });
      await page.waitForTimeout(800);
      await SCREENS[mode][i](page);
      await page.waitForTimeout(1200);
      await page.screenshot({ path: path.join(OUT, `${mode}-${i + 1}.png`) });
      await ctx.close();
    }
  }
  await browser.close();
})();
