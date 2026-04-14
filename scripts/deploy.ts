/**
 * Deploy ZKOracleRegistry to any EVM network.
 *
 * Usage (from contracts/ directory):
 *   forge build
 *   NETWORK=base-sepolia bun run scripts/deploy.ts
 *   NETWORK=base-mainnet bun run scripts/deploy.ts
 *   EVM_RPC_URL=http://localhost:8545 bun run scripts/deploy.ts
 *
 * Required:
 *   ORACLE_PRIVATE_KEY         — deployer wallet private key
 *   NETWORK or EVM_RPC_URL     — target network (NETWORK takes presets, EVM_RPC_URL for custom)
 *
 * Optional:
 *   ORACLE_ADDRESS             — if the oracle wallet differs from the deployer
 */

import { ethers } from "ethers"
import { readFileSync } from "fs"
import { join } from "path"

// ─── Network registry ─────────────────────────────────────────────────────────

interface NetworkInfo {
    rpcUrl: string
    explorer: string        // block explorer base URL
    forgeChain?: string     // forge --chain value (if different from numeric chainId)
}

const NETWORKS: Record<string, NetworkInfo> = {
    "base-sepolia": {
        rpcUrl:     "https://sepolia.base.org",
        explorer:   "https://sepolia.basescan.org",
        forgeChain: "base-sepolia",
    },
    "base-mainnet": {
        rpcUrl:     "https://mainnet.base.org",
        explorer:   "https://basescan.org",
        forgeChain: "base",
    },
    "eth-mainnet": {
        rpcUrl:     "https://ethereum-rpc.publicnode.com",
        explorer:   "https://etherscan.io",
        forgeChain: "mainnet",
    },
    "eth-sepolia": {
        rpcUrl:     "https://rpc.sepolia.org",
        explorer:   "https://sepolia.etherscan.io",
        forgeChain: "sepolia",
    },
    "polygon-mainnet": {
        rpcUrl:     "https://polygon-rpc.com",
        explorer:   "https://polygonscan.com",
        forgeChain: "polygon",
    },
    "arbitrum-mainnet": {
        rpcUrl:     "https://arb1.arbitrum.io/rpc",
        explorer:   "https://arbiscan.io",
        forgeChain: "arbitrum",
    },
    "local": {
        rpcUrl:     "http://localhost:8545",
        explorer:   "",
    },
}

// Known explorers by chainId for when EVM_RPC_URL is used directly
const EXPLORER_BY_CHAIN: Record<string, string> = {
    "1":        "https://etherscan.io",
    "11155111": "https://sepolia.etherscan.io",
    "8453":     "https://basescan.org",
    "84532":    "https://sepolia.basescan.org",
    "137":      "https://polygonscan.com",
    "42161":    "https://arbiscan.io",
}

// ─── Resolve network config ───────────────────────────────────────────────────

function resolveNetwork(): { rpcUrl: string; preset?: NetworkInfo } {
    const networkName = process.env.NETWORK
    const customRpc   = process.env.EVM_RPC_URL

    if (networkName) {
        const preset = NETWORKS[networkName]
        if (!preset) {
            console.error(`Unknown NETWORK="${networkName}". Available presets:`)
            Object.keys(NETWORKS).forEach(n => console.error(`  ${n}`))
            console.error(`Or set EVM_RPC_URL directly for a custom endpoint.`)
            process.exit(1)
        }
        return { rpcUrl: preset.rpcUrl, preset }
    }

    if (customRpc) {
        return { rpcUrl: customRpc }
    }

    console.error("Set NETWORK=<name> or EVM_RPC_URL=<rpc> to specify the target network.")
    console.error("Available NETWORK presets:")
    Object.keys(NETWORKS).forEach(n => console.error(`  ${n}`))
    process.exit(1)
}

// ─── Load compiled bytecode ───────────────────────────────────────────────────

function loadArtifact(): { abi: any[]; bytecode: string } {
    const candidates = [
        join(import.meta.dir, "../out/ZKOracleRegistry.sol/ZKOracleRegistry.json"),
        join(import.meta.dir, "../artifacts/ZKOracleRegistry.json"),
    ]

    for (const path of candidates) {
        try {
            const raw = JSON.parse(readFileSync(path, "utf8"))
            const bytecode = raw.bytecode?.object ?? raw.bytecode
            if (bytecode) return { abi: raw.abi, bytecode }
        } catch {
            // not found, try next
        }
    }

    console.error("No compiled artifact found. Run `forge build` first.")
    process.exit(1)
}

// ─── Deploy ───────────────────────────────────────────────────────────────────

async function main() {
    const privateKey = process.env.ORACLE_PRIVATE_KEY
    if (!privateKey) {
        console.error("Missing ORACLE_PRIVATE_KEY")
        process.exit(1)
    }

    const { rpcUrl, preset } = resolveNetwork()

    const provider = new ethers.JsonRpcProvider(rpcUrl)
    const deployer  = new ethers.Wallet(privateKey, provider)

    const network = await provider.getNetwork()
    const chainId = network.chainId.toString()
    const balance = await provider.getBalance(deployer.address)

    const explorerUrl = preset?.explorer ?? EXPLORER_BY_CHAIN[chainId] ?? ""
    const forgeChain  = preset?.forgeChain ?? chainId

    console.log(`Network  : ${network.name} (chainId ${chainId})`)
    console.log(`RPC      : ${rpcUrl}`)
    console.log(`Deployer : ${deployer.address}`)
    console.log(`Balance  : ${ethers.formatEther(balance)} ETH`)
    console.log()

    if (balance === 0n) {
        console.error("Deployer wallet has no ETH — fund it first")
        process.exit(1)
    }

    const oracleAddress = process.env.ORACLE_ADDRESS ?? deployer.address
    console.log(`Initial oracle address: ${oracleAddress}`)

    const { abi, bytecode } = loadArtifact()
    const factory = new ethers.ContractFactory(abi, bytecode, deployer)

    console.log("\nDeploying ZKOracleRegistry...")
    const contract  = await factory.deploy(oracleAddress)
    const deployTx  = contract.deploymentTransaction()!

    console.log(`Tx hash  : ${deployTx.hash}`)
    console.log("Waiting for confirmation...")

    await contract.waitForDeployment()
    const address = await contract.getAddress()

    console.log(`\nDeployed : ${address}`)

    if (explorerUrl) {
        console.log(`Explorer : ${explorerUrl}/address/${address}`)
    }

    console.log("\nAdd to your server/.env:")
    console.log(`CONTRACT_ADDRESS=${address}`)

    console.log("\nVerify on Sourcify (no API key needed):")
    console.log(`  forge verify-contract ${address} ZKOracleRegistry --chain ${forgeChain} --verifier sourcify`)
}

main().catch(err => {
    console.error(err)
    process.exit(1)
})
