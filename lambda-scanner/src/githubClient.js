// githubClient.js — download a given commit's code from GitHub and extract it locally
//
// The engine only understands local paths, so "fetching the code" happens here:
//   download https://github.com/{repo}/archive/{commitSha}.tar.gz
//   extract to /tmp/{jobId}/ (Lambda's only writable directory)
//   return that directory path, hand it to scanner.runScan()

import fs from 'fs';
import { Readable } from 'stream';
import { pipeline } from 'stream/promises';
import * as tar from 'tar';

// Download + extract repo@commitSha to /tmp/{jobId}/ (token required for private repos, optional for public); returns that local dir path.
export const fetchRepo = async (repo, commitSha, jobId, githubToken) => {
  const dest = `/tmp/${jobId}`;
  fs.mkdirSync(dest, { recursive: true });

  const url = `https://github.com/${repo}/archive/${commitSha}.tar.gz`;
  const headers = githubToken ? { Authorization: `token ${githubToken}` } : {};

  const res = await fetch(url, { headers, redirect: 'follow' });
  if (!res.ok) {
    throw new Error(
      `GitHub download failed: ${res.status} ${res.statusText} (${url})`
    );
  }

  // Tarball top level is a single {repo}-{sha}/ dir; strip:1 removes it so files land under /tmp/{jobId}/ and scan paths stay repo-relative.
  await pipeline(
    Readable.fromWeb(res.body),
    tar.x({ cwd: dest, strip: 1 })
  );

  return dest;
};

export default { fetchRepo };
