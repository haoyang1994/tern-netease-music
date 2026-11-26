import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import https from 'node:https';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { Readable } from 'node:stream';
import test from 'node:test';
import { albumURL, cover } from '../helpers/macos/cover.mjs';
import { readTrack } from '../helpers/macos/track.mjs';

test('SQLite metadata requires an exact active ID and leaves the database untouched', context => {
    const root = mkdtempSync(join(tmpdir(), 'tern-netease-tracks-'));
    context.after(() => rmSync(root, { recursive: true }));
    const file = join(root, 'track.sqlite3');
    const db = new DatabaseSync(file);
    db.exec('CREATE TABLE dbTrack(id TEXT PRIMARY KEY, jsonStr TEXT); CREATE TABLE historyTracks(id TEXT PRIMARY KEY, jsonStr TEXT);');
    const insert = db.prepare('INSERT INTO dbTrack VALUES (?, ?)');
    insert.run('123', JSON.stringify({
        id: 123, name: 'Example\nSong', artists: [{ name: 'Artist' }],
        album: { name: 'Album', picUrl: 'http://p4.music.126.net/example==/cover.jpg?token=placeholder' },
        duration: 3000, userId: 'excluded',
    }));
    insert.run('124', JSON.stringify({ id: 126, name: 'Wrong ID' }));
    db.prepare('INSERT INTO historyTracks VALUES (?, ?)').run('125', JSON.stringify({ id: '125', name: 'Exact fallback' }));
    db.close();

    const before = readFileSync(file);
    assert.deepEqual(readTrack(file, '123'), {
        id: '123', title: 'Example Song', artist: 'Artist', album: 'Album', duration: 3000,
        art_url: 'https://p4.music.126.net/example==/cover.jpg?param=512y512',
    });
    assert.equal(readTrack(file, '124'), null);
    assert.equal(readTrack(file, '125')?.title, 'Exact fallback');
    assert.equal(readTrack(file, '126'), null);
    assert.equal(readTrack(file, '123 OR 1=1'), null);
    assert.deepEqual(readdirSync(root), ['track.sqlite3']);
    assert.deepEqual(readFileSync(file), before);
    writeFileSync(file + '-wal', '');
    assert.equal(readTrack(file, '123'), null);
});

test('Cover URLs require the NetEase CDN host and a safe path', () => {
    for (const url of [
        'https://p4.music.126.net.evil.example/path.png',
        'https://user:password@p4.music.126.net/path.png',
        'https://p4.music.126.net:8080/path.png',
        'ftp://p4.music.126.net/path.png',
        'https://p4.music.126.net/path%2Fother.png',
    ]) {
        assert.equal(albumURL(url), null, url);
    }
});

test('Cover requests reject redirects and use exact track IDs for catalogue fallback', async context => {
    const requests = [];
    const jpeg = Buffer.from([0xff, 0xd8, 0xff]);
    const stub = context.mock.method(https, 'get', (url, options, callback) => {
        assert.equal(options.headers.Cookie, undefined);
        requests.push(url.href);
        queueMicrotask(() => {
            const detail = Buffer.from(JSON.stringify({ songs: [
                { id: 456, al: { picUrl: 'https://p4.music.126.net/wrong.jpg' } },
                { id: 123, al: { picUrl: 'https://p4.music.126.net/right.jpg' } },
            ] }));
            const response = Readable.from([url.hostname === 'music.163.com' ? detail : jpeg]);
            response.statusCode = url.pathname === '/first.jpg' ? 302 : 200;
            response.headers = { location: 'https://example.invalid/image.jpg' };
            callback(response);
        });
        return new EventEmitter();
    });
    syncBuiltinESMExports();
    context.after(() => {
        stub.mock.restore();
        syncBuiltinESMExports();
    });
    assert.deepEqual(await cover('123', 'http://p4.music.126.net/first.jpg?irrelevant=1'),
        { mime: 'image/jpeg', data: jpeg.toString('base64') });
    assert.deepEqual(requests.map(url => new URL(url).pathname), [
        '/first.jpg', '/api/v3/song/detail', '/right.jpg',
    ]);
    assert.deepEqual(requests.map(url => new URL(url).hostname), [
        'p4.music.126.net', 'music.163.com', 'p4.music.126.net',
    ]);
});
