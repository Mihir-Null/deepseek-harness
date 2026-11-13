// Generates tests/data/url-table.json: what Node's WHATWG URL gives for the inputs the dsh
// utility sources parse. Run: node tests/gen/gen-url-table.mjs > tests/data/url-table.json
const INPUTS = [
  'http://example.com', 'http://example.com/', 'HTTP://EXAMPLE.COM:80/a/b', 'https://example.com:443/x?y=1#z',
  'https://example.com:8443/a/./b/../c', 'http://user:pa ss@host.example/p', 'http://user@host/', 'http://:pw@host/',
  'http://127.0.0.1:7897', 'http://127.1/', 'http://2130706433/', 'http://0x7f.0.0.1/', 'http://0177.0.0.1:8080/',
  'http://127.999.1.1/', 'http://1.2.3.4.5/', 'http://256.1.1.1/', 'http://[::1]:3000/a', 'http://[::ffff:127.0.0.1]/',
  'http://[::FFFF:10.0.0.1]:8080/', 'http://[2001:db8:0:0:1:0:0:1]/', 'http://[2001:DB8::]/', 'http://[::]/',
  'http://[1::2::3]/', 'http://[::1/', 'http://localhost:3000/a', 'http://app.localhost/', 'http://example.com./a',
  'http://example.COM/a', 'http://sub.example.com/a', 'ws://example.com/', 'wss://example.com:443/', 'ftp://proxy.example',
  'socks5://127.0.0.1:1080', 'socks5h://user:pw@host:1080', 'not a url', '', '   ', 'example.com', '//example.com/x',
  'http://', 'http:///x', 'http://exa mple.com/', 'http://example.com:99999/', 'http://example.com:abc/',
  'https://host/tools/dsh/', 'https://host', 'dsh-app://app/', 'dsh-app://app/index.html', 'about:blank',
  'mailto:someone@example.com', 'data:image/png;base64,AAAA', 'file:///app/', 'file:///C:/x/y', 'file://host/share/x',
  'https://github.com/owner/repo', 'https://github.com/owner/repo.git', 'https://github.com/owner/repo/',
  'https://GitHub.com/owner/repo', 'https://github.com/owner/repo?x=1', 'https://github.com/owner/repo#readme',
  'https://user:pw@github.com/owner/repo', 'https://registry.npmjs.org', 'https://registry.npmjs.org/',
  'http://registry.example:4873/', 'https://example.com/a b/c%20d/%zz?q=a b"c#f g', 'https://example.com/\u00e9/\u4e2d?\u00e9#\u00e9',
  'https://b\u00fccher.example/', 'https://\u4f8b\u3048.jp/', 'https://xn--bcher-kva.example/', 'https://example.com/a/b/c/../../..',
  'https://example.com/a/%2e%2E/b', 'https://example.com//a//b', 'https://example.com\\a\\b', '  https://example.com/x \n',
  'ht\ttps://exam\nple.com/', 'https://example.com:443', 'http://example.com:443/', 'https://example.com/?', 'https://example.com/#',
  'http://[::ffff:7f00:1]/', 'http://[0:0:0:0:0:0:0:1]/', 'http://[1:2:3:4:5:6:7:8]/', 'http://[1:0:0:2:0:0:0:3]/', 'http://1.1/',
  'http://999999999999/', 'http://0x/', 'http://09/', 'http://1.2.3/', 'http://example.com:0/', 'http://example.com:65535/',
  'http://example.com:65536/', 'https://example.com/a?b#c?d#e', 'x:', 'x:/a/b/../c', 'x://host:1/p?q#f', 'x://HOST/', 'a+b.c-d:foo',
  '1x://bad', 'http://a.b.c.d.e.f/', 'http://%65xample.com/', 'http://ex%2Fample.com/', 'http://example.com:/a', 'http://@/',
  'https://probe.invalid/plain', 'http://10.1.2.3/a', 'http://[::ffff:a00:1]:8080/', 'http://notlocalhost:8080/',
]
const RESOLVE = [
  ['api/file?path=%2Fwork%2Fa.png', 'https://host/tools/dsh/'], ['api/file?path=x', 'https://host'],
  ['api/file?path=x', 'https://host/tools/dsh/index.html'], ['api/file?path=x', 'dsh-app://app/'],
  ['api/file?path=x', 'dsh-app://app/index.html'], ['icons/a.svg', 'https://market.example/index/v1/index.json'],
  ['./icons/a.svg', 'https://market.example/index.json'], ['../icons/a.svg', 'https://market.example/a/b/index.json'],
  ['/icons/a.svg', 'https://market.example/a/b/index.json'], ['//cdn.example/a.svg', 'https://market.example/index.json'],
  ['//cdn.example/a.svg', 'http://market.example/index.json'], ['https://other.example/a.png', 'https://market.example/index.json'],
  ['http://other.example/a.png', 'https://market.example/index.json'], ['a.svg?v=1#f', 'http://localhost:8080/m/index.json'],
  ['?v=2', 'https://market.example/a/index.json?old=1#frag'], ['#frag', 'https://market.example/a/index.json?old=1'],
  ['', 'https://market.example/a/index.json?old=1#frag'], ['javascript:alert(1)', 'https://market.example/index.json'],
  ['data:image/png;base64,AAAA', 'https://market.example/index.json'], ['a.svg', 'about:blank'], ['#f', 'about:blank'],
  ['http://[bad', 'https://market.example/index.json'], ['https:icons/a.svg', 'https://market.example/x/index.json'],
  ['http:icons/a.svg', 'https://market.example/x/index.json'], ['a/../../b/./c', 'https://market.example/x/y/index.json'],
  ['\\\\cdn.example\\a.svg', 'https://market.example/index.json'], ['a b.svg', 'https://market.example/index.json'],
  ['file:///etc/passwd', 'https://market.example/index.json'], ['a.svg', 'file:///srv/market/index.json'],
]
function describe(url) {
  return url === null ? null : {
    href: url.href, protocol: url.protocol, hostname: url.hostname, port: url.port, pathname: url.pathname,
    origin: url.origin, username: url.username, password: url.password, search: url.search, hash: url.hash,
  }
}
process.stdout.write(JSON.stringify({
  parse: INPUTS.map(input => ({ input, url: describe(URL.parse(input)) })),
  resolve: RESOLVE.map(([reference, base]) => ({ reference, base, url: describe(URL.parse(reference, base)) })),
}, null, 1) + '\n')
