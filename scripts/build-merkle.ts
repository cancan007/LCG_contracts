import { readFileSync, writeFileSync } from "node:fs";
import { MerkleTree } from "merkletreejs";
import keccak256 from "keccak256";
import { AbiCoder, getAddress, keccak256 as solidityKeccak } from "ethers";

type ClaimInput = {
  user: string;
  tokenId: string;
  tokenURI: string;
  // metadata object. We'll canonicalize it.
  metadata: any;
};

type InputFile = {
  epochId: number | string;
  claims: ClaimInput[];
};

const abi = AbiCoder.defaultAbiCoder();

function canonicalize(value: any): string {
  // Canonical JSON: recursively sort object keys, no extra whitespace.
  if (value === null || value === undefined) return "null";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("Non-finite number in metadata");
    return String(value);
  }
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return "[" + value.map(canonicalize).join(",") + "]";
  }
  if (typeof value === "object") {
    const keys = Object.keys(value).sort();
    return "{" + keys.map((k) => JSON.stringify(k) + ":" + canonicalize(value[k])).join(",") + "}";
  }
  throw new Error(`Unsupported metadata type: ${typeof value}`);
}

function metadataContentHash(metadataJsonCanonical: string): string {
  // Solidity side does: keccak256(bytes(metadataJsonCanonical))
  // We reproduce with ethers: keccak256(abi.encode(bytes, str)) or keccak256(Buffer)
  // The simplest: keccak256 of UTF-8 bytes.
  const bytes = Buffer.from(metadataJsonCanonical, "utf8");
  return "0x" + keccak256(bytes).toString("hex");
}

function leaf(epochId: bigint, user: string, tokenId: bigint, contentHash: string): string {
  const encoded = abi.encode(["uint256", "address", "uint256", "bytes32"], [epochId, user, tokenId, contentHash]);
  return solidityKeccak(encoded);
}

function main() {
  const inputPath = process.argv[2] ?? "./airdrop/epoch-1.json";
  const outputPath = process.argv[3] ?? "./airdrop/epoch-1.proofs.json";

  const input: InputFile = JSON.parse(readFileSync(inputPath, "utf8"));
  const epochId = BigInt(input.epochId);

  const normalized = input.claims.map((c) => {
    const user = getAddress(c.user);
    const tokenId = BigInt(c.tokenId);
    const metadataJsonCanonical = canonicalize(c.metadata);
    const contentHash = metadataContentHash(metadataJsonCanonical);
    const l = leaf(epochId, user, tokenId, contentHash);
    return {
      user,
      tokenId: tokenId.toString(),
      tokenURI: c.tokenURI,
      metadataJsonCanonical,
      metadataContentHash: contentHash,
      leaf: l,
    };
  });

  const leavesBuf = normalized.map((x) => Buffer.from(x.leaf.slice(2), "hex"));
  const tree = new MerkleTree(leavesBuf, keccak256, { sortPairs: true });
  const root = tree.getHexRoot();

  const claims = normalized.map((x) => {
    const proof = tree.getHexProof(Buffer.from(x.leaf.slice(2), "hex"));
    return {
      user: x.user,
      tokenId: x.tokenId,
      tokenURI: x.tokenURI,
      metadataJsonCanonical: x.metadataJsonCanonical,
      metadataContentHash: x.metadataContentHash,
      leaf: x.leaf,
      proof,
    };
  });

  const out = {
    epochId: input.epochId,
    merkleRoot: root,
    sortPairs: true,
    leafSpec: "keccak256(abi.encode(epochId, user, tokenId, keccak256(bytes(metadataJsonCanonical))))",
    claims,
  };

  writeFileSync(outputPath, JSON.stringify(out, null, 2));
  console.log("✅ root:", root);
  console.log("✅ wrote:", outputPath);
}

main();
