import { realpathSync } from 'node:fs';
import { get } from 'node:https';

const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
const MAX_DETAIL_BYTES = 256 * 1024;
const TIMEOUT_MS = 5000;

export function albumURL(value) {
    if (typeof value !== 'string') return null;
    const url = URL.parse(value);
    if (!url || !['http:', 'https:'].includes(url.protocol) ||
        !/^p\d{1,2}\.music\.126\.net$/.test(url.hostname) ||
        url.username || url.password || url.port ||
        !/^\/(?:[a-zA-Z0-9_-]+={0,2}\/)*[a-zA-Z0-9_.-]+$/.test(url.pathname)) {
        return null;
    }
    // Older catalogue entries carry an HTTP URL on the same HTTPS-capable CDN.
    return new URL(`https://${url.hostname}${url.pathname}?param=512y512`);
}

function read(url, limit) {
    return new Promise((resolve, reject) => {
        const request = get(url, {
            signal: AbortSignal.timeout(TIMEOUT_MS),
            headers: { 'User-Agent': 'Mozilla/5.0', Referer: 'https://music.163.com/' },
        }, async response => {
            // Do not follow redirects or send account identifiers, cookies or history.
            if (response.statusCode !== 200 || Number(response.headers['content-length']) > limit) {
                response.destroy();
                reject(new Error('Unexpected NetEase response'));
                return;
            }
            try {
                const chunks = [];
                let size = 0;
                for await (const chunk of response) {
                    size += chunk.length;
                    if (size > limit) throw new Error('NetEase response is too large');
                    chunks.push(chunk);
                }
                resolve(Buffer.concat(chunks));
            } catch (error) {
                reject(error);
            }
        });
        request.on('error', reject);
    });
}

async function image(url) {
    const bytes = await read(url, MAX_IMAGE_BYTES);
    if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
        return { mime: 'image/jpeg', data: bytes.toString('base64') };
    }
    if (bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))) {
        return { mime: 'image/png', data: bytes.toString('base64') };
    }
    throw new Error('Unexpected NetEase image format');
}

export async function cover(id, localAlbumURL) {
    if (!/^[1-9]\d*$/.test(id) || !Number.isSafeInteger(Number(id))) {
        throw new Error('Invalid NetEase track ID');
    }
    const local = albumURL(localAlbumURL);
    if (local) {
        const result = await image(local).catch(() => null);
        if (result) return result;
    }
    const detail = new URL('https://music.163.com/api/v3/song/detail');
    detail.searchParams.set('c', `[{"id":${id}}]`);
    const catalogue = JSON.parse(await read(detail, MAX_DETAIL_BYTES));
    const song = catalogue.songs?.find(song => String(song.id) === id);
    const url = albumURL(song?.al?.picUrl);
    if (!url || url.href === local?.href) throw new Error('NetEase cover is unavailable');
    return image(url);
}

if (process.argv[1] && realpathSync(process.argv[1]) === import.meta.filename) {
    try {
        const [, , id, url] = process.argv;
        process.stdout.write(JSON.stringify(await cover(id, url)));
    } catch {
        process.exitCode = 1;
    }
}
