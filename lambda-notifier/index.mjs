import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";
import { SSMClient, GetParameterCommand } from "@aws-sdk/client-ssm";

const s3 = new S3Client({});
const sns = new SNSClient({});
const ssm = new SSMClient({});

// Cache GitHub token for the lifetime of the Lambda container.
let cachedToken = null;
async function getGithubToken() {
  if (cachedToken) return cachedToken;
  const param = process.env.GITHUB_TOKEN_PARAM;
  if (!param) return null;
  try {
    const res = await ssm.send(new GetParameterCommand({ Name: param, WithDecryption: true }));
    cachedToken = res.Parameter.Value;
    return cachedToken;
  } catch (e) {
    console.warn(`Could not load GitHub token from SSM (${param}): ${e.message}`);
    return null;
  }
}

async function streamToString(stream) {
  const chunks = [];
  for await (const chunk of stream) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf-8");
}

async function postGitHubComment(owner, repo, prNumber, body, token) {
  const url = `https://api.github.com/repos/${owner}/${repo}/issues/${prNumber}/comments`;
  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ body }),
  });
  if (!response.ok) {
    const err = await response.text();
    throw new Error(`GitHub API ${response.status}: ${err}`);
  }
}

// Sets the "CodeGuard Security Scan" commit status on the scanned SHA.
// When this context is required in branch protection rules, a "failure" state
// prevents the PR from being merged until findings are resolved.
async function createGitHubStatus(owner, repo, sha, state, description, token) {
  const response = await fetch(
    `https://api.github.com/repos/${owner}/${repo}/statuses/${sha}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        state,
        description,
        context: "CodeGuard Security Scan",
      }),
    }
  );
  if (!response.ok) {
    throw new Error(`GitHub API ${response.status}: ${await response.text()}`);
  }
}

function getJobIdFromS3Key(key) {
  const parts = key.split("/");
  if (parts.length < 3) throw new Error(`Unexpected S3 key format: ${key}`);
  return parts[1];
}

export const handler = async (event) => {
  const bucket = process.env.S3_BUCKET_NAME;

  if (!event.Records?.length) throw new Error("Missing S3 Records in event");

  const rawKey = event.Records[0].s3.object.key;
  const key = decodeURIComponent(rawKey.replace(/\+/g, " "));
  const jobId = getJobIdFromS3Key(key);

  console.log(`Notifier triggered: bucket=${bucket} key=${key} jobId=${jobId}`);

  // Read report.json
  const reportRes = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const report = JSON.parse(await streamToString(reportRes.Body));

  // Read metadata.json
  const metaRes = await s3.send(
    new GetObjectCommand({ Bucket: bucket, Key: `jobs/${jobId}/metadata.json` })
  );
  const metadata = JSON.parse(await streamToString(metaRes.Body));

  const prNumber  = metadata.prNumber ?? null;
  const commitSha = metadata.commitSha;
  const highCount = report.summary?.high ?? 0;
  const passed    = highCount === 0;

  // ── SNS alert for high-severity findings ─────────────────────────────────
  if (!passed) {
    const top = report.findings?.[0];
    const emailMessage = `
CodeGuard Security Scan Report

Repository: ${report.repo}
Total Findings: ${report.summary.total}
High Severity:   ${report.summary.high}
Medium Severity: ${report.summary.medium}
Low Severity:    ${report.summary.low}

Most Critical Finding
---------------------
Severity:    ${top?.severity ?? "N/A"}
Type:        ${top?.type ?? "N/A"}
Location:    ${top?.file ?? "N/A"}${top?.line ? ` (Line ${top.line})` : ""}
Description: ${top?.message ?? "No description available"}

Please review and remediate the above before merging.

— CodeGuard Automated Security Platform
`.trim();

    await sns
      .send(new PublishCommand({
        TopicArn: process.env.SNS_TOPIC_ARN,
        Subject: "CodeGuard Security Alert: High Severity Findings Detected",
        Message: emailMessage,
      }))
      .catch((e) => console.error("SNS publish failed:", e.message));

    console.log(`SNS alert sent for jobId=${jobId} (${highCount} high-severity findings)`);
  }

  // ── GitHub commit status (merge gate) + PR comment ───────────────────────
  if (!prNumber) {
    console.log("No prNumber in metadata — skipping PR comment and status check (push event)");
    return { statusCode: 200, jobId, prNumber: null, highCount };
  }

  const token = await getGithubToken();
  if (!token) {
    console.warn("No GitHub token available — skipping PR comment and status check");
    return { statusCode: 200, jobId, prNumber, highCount };
  }

  const [owner, repo] = report.repo.split("/");

  // Set commit status — blocks merge when state="failure" and the
  // "CodeGuard Security Scan" context is required in branch protection.
  await createGitHubStatus(
    owner, repo, commitSha,
    passed ? "success" : "failure",
    passed
      ? "No high-severity findings — safe to merge"
      : `${highCount} high-severity finding(s) detected — merge blocked`,
    token
  ).catch((e) => console.error("GitHub status update failed:", e.message));

  console.log(`GitHub status set to "${passed ? "success" : "failure"}" for sha=${commitSha}`);

  // Post PR comment with clear pass/fail result
  const statusLine = passed
    ? "✅ **No high-severity findings detected. This PR is safe to merge.**"
    : `❌ **${highCount} high-severity finding(s) detected. Merge is blocked until resolved.**`;

  const topIssue = report.findings?.[0]?.message ?? "No findings";

  const comment = `## CodeGuard Scan Results

**Repository:** ${report.repo}

${statusLine}

| Severity | Count |
|----------|-------|
| High     | ${report.summary?.high ?? 0} |
| Medium   | ${report.summary?.medium ?? 0} |
| Low      | ${report.summary?.low ?? 0} |
| **Total**| **${report.summary?.total ?? 0}** |

**Top Issue:** ${topIssue}
`;

  await postGitHubComment(owner, repo, prNumber, comment, token).catch((e) =>
    console.error("GitHub PR comment failed:", e.message)
  );

  console.log(`PR comment posted: repo=${report.repo} pr=${prNumber}`);

  return { statusCode: 200, jobId, prNumber, highCount };
};
