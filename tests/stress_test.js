import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

/**
 * K6 Stress Test for La Roca Micro-KV
 * Focus: Namespace validation (/keys/), Capacity limits (507),
 * and high-concurrency stability under the new routing logic.
 */

// 1. Environment Variable Extraction
const MAX_SLOTS_RAW = __ENV.MAX_SLOTS || "4096";
const MAX_SLOTS = parseInt(MAX_SLOTS_RAW.split(' ')[0], 10);

// Pointing to the new base API
const API_URL = "http://localhost:8080/keys";

export const options = {
    // 50 Virtual Users (VUs) - Intensive load for raw Assembly
    vus: 50,
    // Attempt to exceed capacity to trigger Disk/Memory boundary protection
    iterations: MAX_SLOTS + 100,
    discardResponseBodies: true,
    thresholds: {
        // We expect < 10ms even with the new prefix parsing logic
        http_req_duration: ['p(95)<10'],
    },
};

export default function () {
    // Unique ID for the current iteration to ensure deterministic sharding
    const id = exec.scenario.iterationInTest;

    // URL Construction: Now following the /keys/{key} contract
    // 'z' prefix ensures we hit db/z.db for predictable saturation
    const url = `${API_URL}/z_stress_${id}`;
    const payload = "val";

    const params = {
        tags: {
            // Aggregate metrics under one name to save K6 memory
            name: 'PostToKeysNamespace'
        },
    };

    // Execute POST to the new namespace
    const res = http.post(url, payload, params);

    // Validation
    // 200 = Stored successfully
    // 507 = Shard capacity reached (Insufficient Storage)
    check(res, {
        'status is 200 or 507': (r) => r.status === 200 || r.status === 507,
    });

    // Log saturation points every 500 iterations
    if (res.status === 507 && id % 500 === 0) {
        console.log(`[!] Shard Z Saturated: 507 received at index ${id}`);
    }
}