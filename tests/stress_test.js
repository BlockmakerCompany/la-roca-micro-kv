import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';
import { SharedArray } from 'k6/data';

/**
 * K6 Stress Test for La Roca Micro-KV — SWMR showcase.
 *
 * Unlike the old test (all POSTs pinned to shard 'z'), this one exercises the
 * v1.2.0 concurrency model directly:
 *   1. Keys are spread across all 26 alphabetic shards (a..z), so each shard
 *      contends only on its own seq_lock instead of a single global lock.
 *   2. Mixed workload: ~80% GET (lock-free reads with seqlock retry) and
 *      ~20% POST (group-commit write path), proving readers keep serving while
 *      the writer does its deferred flush.
 *   3. Concurrency is tunable up to hundreds/thousands of VUs to show the
 *      futex-based backpressure keeping HTTP failures at 0 under a "tsunami".
 *
 * Tuning (all via env, see README "Testing & Validation"):
 *   VUS          virtual users (default 500)
 *   DURATION     test duration (default '30s')
 *   READ_RATIO   fraction of GETs, 0..1 (default 0.8)
 *   POOL_KEYS    preloaded keys, spread round-robin across a..z (default 1040)
 */

const API_URL = __ENV.API_URL || 'http://localhost:8080/keys';
const VUS = parseInt(__ENV.VUS || '500', 10);
const DURATION = __ENV.DURATION || '30s';
const READ_RATIO = parseFloat(__ENV.READ_RATIO || '0.8');
const POOL_KEYS = parseInt(__ENV.POOL_KEYS || '1040', 10);

const LETTERS = 'abcdefghijklmnopqrstuvwxyz'.split('');

// Shared pool of pre-existing keys, one per VU copy (SharedArray is loaded once).
// Letter = shard index (a=0 .. z=25); the numeric suffix keeps keys unique.
const keys = new SharedArray('keys', function () {
    const arr = [];
    for (let i = 0; i < POOL_KEYS; i++) {
        arr.push(`${LETTERS[i % 26]}_pool_${i}`);
    }
    return arr;
});

export const options = {
    vus: VUS,
    duration: DURATION,
    discardResponseBodies: true,
    thresholds: {
        // The engine's backpressure should keep failures at 0. We allow 0.1%
        // slack for loopback TCP hiccups from the *tester* (k6 saturates `lo`
        // before La Roca saturates) — set to `rate==0` for a strict demo.
        http_req_failed: ['rate<0.001'],
    },
};

// Preload the pool so the 80% GETs hit real keys and measure the lock-free
// read path (a GET on a missing key is also cheap, but it does not exercise
// the seqlock retry against a live B+Tree the way a hit does).
export function setup() {
    const payload = 'v';
    for (let i = 0; i < keys.length; i++) {
        http.post(`${API_URL}/${keys[i]}`, payload, {
            headers: { 'Connection': 'keep-alive' },
            tags: { name: 'warmup' },
        });
    }
    return {};
}

export default function () {
    const isRead = Math.random() < READ_RATIO;

    const params = {
        headers: { 'Connection': 'keep-alive' },
        tags: { name: isRead ? 'GetFromKeys' : 'PostToKeys' },
    };

    if (isRead) {
        const key = keys[Math.floor(Math.random() * keys.length)];
        const res = http.get(`${API_URL}/${key}`, params);
        check(res, { 'GET 200': (r) => r.status === 200 });
        return;
    }

    // Write path: unique key spread across a random shard on every iteration.
    const letter = LETTERS[Math.floor(Math.random() * LETTERS.length)];
    const id = `${exec.vu.idInTest}_${exec.scenario.iterationInTest}`;
    const url = `${API_URL}/${letter}_stress_${id}`;
    const res = http.post(url, 'val', params);
    check(res, { 'POST 200': (r) => r.status === 200 });
}
