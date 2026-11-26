import { existsSync, realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { pathToFileURL } from 'node:url';
import { albumURL } from './cover.mjs';

const databasePath = join(homedir(), 'Library', 'Application Support', 'com.netease.163music',
    'Documents', 'storage', 'sqlite_storage.sqlite3');
const queries = [
    'SELECT jsonStr AS json FROM dbTrack WHERE id = ?',
    'SELECT track AS json FROM web_track WHERE tid = ?',
    'SELECT jsonStr AS json FROM historyTracks WHERE id = ?',
];

function text(value) {
    return typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 500) : '';
}

function trackFields(raw, id) {
    if (typeof raw !== 'string' || raw.length > 256 * 1024) return null;
    const track = JSON.parse(raw);
    if (String(track?.id) !== id) return null;
    const title = text(track.name);
    if (!title) return null;
    return {
        id,
        title,
        artist: Array.isArray(track.artists) ? track.artists.map(artist => text(artist?.name)).filter(Boolean).join(' / ') : '',
        album: text(track.album?.name),
        duration: Number.isSafeInteger(track.duration) && track.duration > 0 ? track.duration : null,
        art_url: albumURL(track.album?.picUrl)?.href ?? null,
    };
}

export function readTrack(path, id) {
    if (!/^[1-9]\d*$/.test(id) || !Number.isSafeInteger(Number(id))) return null;
    const busy = () => existsSync(path + '-journal') || existsSync(path + '-wal');
    if (busy()) return null;
    const before = statSync(path, { bigint: true });
    const uri = pathToFileURL(path);
    // A fresh immutable connection cannot write locks or sidecars to the client directory.
    uri.searchParams.set('immutable', '1');
    const db = new DatabaseSync(uri, { readOnly: true });
    try {
        for (const query of queries) {
            let track;
            try {
                track = trackFields(db.prepare(query).get(id)?.json, id);
            } catch {
                continue;
            }
            if (!track) continue;
            const after = statSync(path, { bigint: true });
            if (busy() || before.ino !== after.ino || before.size !== after.size ||
                before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs) return null;
            return track;
        }
        return null;
    } finally {
        db.close();
    }
}

if (process.argv[1] && realpathSync(process.argv[1]) === import.meta.filename) {
    try {
        process.stdout.write(JSON.stringify(readTrack(databasePath, process.argv[2])));
    } catch {
        process.stdout.write('null');
    }
}
