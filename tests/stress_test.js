import http from 'k6/http';
import { check } from 'k6';

/**
 * K6 Realistic Stress Test for La Roca Micro-KV
 * Focus: Multi-shard distribution, Read/Write Mixed Workload,
 * and realistic B+ Tree traversal.
 */

const API_URL = "http://localhost:8080/keys";

export const options = {
    vus: 50,
    iterations: 10000, // 10,000 iteraciones totales compartidas entre 50 VUs
    discardResponseBodies: true,
    thresholds: {
        // La lectura (GET) va directo a la RAM mapeada -> Exigimos < 5ms
        'http_req_duration{method:GET}': ['p(95)<5'],

        // La escritura (POST) debe atravesar el WAL y el fsync físico -> Tolerancia real
        'http_req_duration{method:POST}': ['p(95)<15'],

        // Cero errores funcionales permitidos
        'checks': ['rate==1.0'],
    },
};

// Generador de llaves que distribuye uniformemente entre los 27 shards
function generateRandomKey() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    // 1. Elegimos el shard al azar (el primer carácter)
    let shardPrefix = chars.charAt(Math.floor(Math.random() * chars.length));
    // 2. Le sumamos un ID largo y aleatorio para evitar concentraciones locales en el B-Tree
    let randomSuffix = Math.floor(Math.random() * 10000000).toString(16);

    return `${shardPrefix}_stress_${randomSuffix}`;
}

export default function () {
    const key = generateRandomKey();
    const url = `${API_URL}/${key}`;
    const payload = "benchmark_payload_data_block";

    // --- 1. ESCRITURA (POST) ---
    const resPost = http.post(url, payload, {
        tags: { name: 'Write_Data' }
    });

    check(resPost, {
        'POST is 200': (r) => r.status === 200,
    });

    // --- 2. LECTURA (GET) ---
    const resGet = http.get(url, {
        tags: { name: 'Read_Data' }
    });

    check(resGet, {
        'GET is 200': (r) => r.status === 200,
    });
}