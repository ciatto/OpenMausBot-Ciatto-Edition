// Integrity and trusted policy-index ordering for imported skills.
import { createHash } from "node:crypto";
import { lstatSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { skillFolderDigest } from "./skill-folder.ts";
import { readReferenceFiles, skillReferencesSha256 } from "./skill-storage.ts";
import type { SkillManifestEntry, SkillListing } from "./skills.ts";

export function contentMatches(resolveDirectory: () => string | null, entry: Pick<SkillManifestEntry, "sha256" | "filesSha256" | "files" | "referencesSha256">): boolean {
  try {
    const directory = resolveDirectory();
    if (!directory) return false;
    const file = join(directory, "SKILL.md");
    if (!lstatSync(file).isFile()) return false;
    if (createHash("sha256").update(readFileSync(file)).digest("hex") !== entry.sha256) return false;
    if (entry.filesSha256 && skillFolderDigest(directory, entry.files ?? []) !== entry.filesSha256) return false;
    if (!entry.referencesSha256) return true;
    const references = readReferenceFiles(directory);
    return references !== null && skillReferencesSha256(references) === entry.referencesSha256;
  } catch {
    return false;
  }
}

export function policyPriority(skill: Pick<SkillListing, "source" | "name">): number {
  return (skill.source === "ciatto:maintenance-personal-v1" && skill.name === "ciatto-cleanup-lifecycle") ||
    (skill.source === "ciatto:enterprise-gap-standard-v1" && skill.name === "ciatto-competency-router") ? 0 : 1;
}
