#!/usr/bin/env node
/**
 * Dria Wallet Generator
 * Usage: node generate-wallets.js <count> [output.json]
 * Compatible with dria.sh wallet format
 */

const fs   = require('fs');
const path = require('path');

async function main() {
    const count  = parseInt(process.argv[2] || '1', 10);
    const outArg = process.argv[3] || 'wallets.json';
    const outFile = path.resolve(outArg);

    if (isNaN(count) || count < 1) {
        console.error('Usage: node generate-wallets.js <count> [output.json]');
        process.exit(1);
    }

    // Try ethers v5 first (used in dria.sh), fall back to ethers v6
    let Wallet;
    try {
        ({ Wallet } = require('ethers'));
    } catch {
        console.error('ethers not found. Install: npm install ethers@5');
        process.exit(1);
    }

    const wallets = [];
    for (let i = 0; i < count; i++) {
        const w = Wallet.createRandom();
        wallets.push({
            address:     w.address,
            private_key: w.privateKey,
        });
    }

    // Merge with existing file if present
    if (fs.existsSync(outFile)) {
        const existing = JSON.parse(fs.readFileSync(outFile, 'utf8'));
        const merged = [...existing, ...wallets];
        // Deduplicate by address
        const seen = new Set();
        const deduped = merged.filter(w => {
            if (seen.has(w.address)) return false;
            seen.add(w.address);
            return true;
        });
        fs.writeFileSync(outFile, JSON.stringify(deduped, null, 2));
        console.log(`Generated ${count} wallet(s), merged into existing ${existing.length} → total ${deduped.length}`);
    } else {
        fs.writeFileSync(outFile, JSON.stringify(wallets, null, 2));
        console.log(`Generated ${count} wallet(s) → ${outFile}`);
    }

    console.log('\nNew wallets:');
    wallets.forEach((w, i) => {
        console.log(`  [${i + 1}] Address: ${w.address}`);
        console.log(`       Key:     ${w.private_key}`);
    });
    console.log('\n⚠  Back up the output file — private keys cannot be recovered!');
}

main().catch(e => { console.error(e); process.exit(1); });
