// scanner.js — wraps the professor-provided SAST engine
//
// Responsibility: run the engine's scanDirectory on an already-downloaded-and-extracted local repo dir,
//                 then normalize the engine's raw vuln objects into the team's agreed report format (CLAUDE.md §3).
//
// Note: the engine only understands local paths, not GitHub/network. Downloading + extraction is githubClient's job.

import path from 'path';
import { scanDirectory } from '../sast-engine/scanner.js';

// Engine rule id (UPPER_SNAKE) -> report type (lower-kebab), e.g. HARDCODED_SECRET -> hardcoded-secret
const toType = (id) => String(id || 'unknown').toLowerCase().replace(/_/g, '-');

// Run SAST on a local dir (e.g. /tmp/{jobId}/), return { summary, findings }; caller adds jobId/repo/commitSha/scannedAt for the full report.
export const runScan = (localPath) => {
  // scanDirectory returns an OBJECT { "filepath": [vuln, ...], ... }; auto-recurses, skips node_modules and hidden dirs.
  const resultsByFile = scanDirectory(localPath);

  // ⚠️ Must flatten to a 1-D array before counting/mapping (verified locally: object -> flat array)
  const all = Object.values(resultsByFile).flat();

  // Field mapping: engine raw object -> report findings format
  const findings = all.map((v) => ({
    severity: v.severity,                 // HIGH/MEDIUM/LOW, 1:1
    type: toType(v.id),                   // SQL_INJECTION -> sql-injection
    file: path.relative(localPath, v.file), // absolute path -> repo-relative (Bala needs it for PR comments)
    line: v.line,                         // 1:1
    message: v.message || v.description,  // prefer message, fall back to description
  }));

  // summary: counts by severity
  const summary = {
    total: findings.length,
    high: findings.filter((f) => f.severity === 'HIGH').length,
    medium: findings.filter((f) => f.severity === 'MEDIUM').length,
    low: findings.filter((f) => f.severity === 'LOW').length,
  };

  return { summary, findings };
};

export default { runScan };
