import { closeSync, constants, existsSync, fstatSync, openSync, readSync, realpathSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { pathToFileURL } from 'node:url';
import { albumURL } from './cover.mjs';

const databasePath = join(homedir(), 'Library', 'Application Support', 'com.netease.163music',
    'Documents', 'storage', 'sqlite_storage.sqlite3');
const playingListMaxBytes = 8 * 1024 * 1024;
const queries = [
    'SELECT jsonStr AS json FROM dbTrack WHERE id = ?',
    'SELECT track AS json FROM web_track WHERE tid = ?',
    'SELECT jsonStr AS json FROM historyTracks WHERE id = ?',
];

function text(value) {
    return typeof value === 'string' ? value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 500) : '';
}

function trackFields(track, id) {
    const trackId = track?.id;
    if (trackId !== id && !(typeof trackId === 'number' && String(trackId) === id)) return null;
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

function readSQLiteTrack(path, id) {
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
                const raw = db.prepare(query).get(id)?.json;
                if (typeof raw !== 'string' || raw.length > 256 * 1024) continue;
                track = trackFields(JSON.parse(raw), id);
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

function readPlayingListTrack(path, id) {
    const fd = openSync(path, constants.O_RDONLY | constants.O_NONBLOCK);
    try {
        const stat = fstatSync(fd);
        const { size } = stat;
        if (!stat.isFile() || size > playingListMaxBytes) return null;
        // Read at most the observed size plus one byte to detect growth during the read.
        const buffer = Buffer.alloc(size + 1);
        let offset = 0;
        while (offset < buffer.length) {
            const count = readSync(fd, buffer, offset, buffer.length - offset, null);
            if (count === 0) break;
            offset += count;
        }
        if (offset !== size) return null;
        const data = JSON.parse(buffer.toString('utf8', 0, offset));
        if (!Array.isArray(data?.list)) return null;
        for (const entry of data.list) {
            const track = trackFields(entry?.track, id);
            if (track) return track;
        }
        return null;
    } finally {
        closeSync(fd);
    }
}

export function readTrack(path, id) {
    if (typeof id !== 'string' || !/^[1-9]\d*$/.test(id) || !Number.isSafeInteger(Number(id))) return null;
    try {
        const track = readSQLiteTrack(path, id);
        if (track) return track;
    } catch {
        // SQLite may be unavailable while NetEase is running.
    }
    try {
        return readPlayingListTrack(join(dirname(path), 'file_storage', 'webdata', 'file', 'playingList'), id);
    } catch {
        return null;
    }
}

if (process.argv[1] && realpathSync(process.argv[1]) === import.meta.filename) {
    try {
        process.stdout.write(JSON.stringify(readTrack(databasePath, process.argv[2])));
    } catch {
        process.stdout.write('null');
    }
}
