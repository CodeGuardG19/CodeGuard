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

function getJobIdFromS3Key(key) {
  // key format: jobs/{jobId}/report.json
  const parts = key.split("/");
  if (parts.length < 3) throw new Error(`Unexpected S3 key format: ${key}`);
  return parts[1];
}

export const handler = async (event) => {
  const bucket = process.env.BUCKET_NAME;

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

  const prNumber = metadata.prNumber ?? null;
  const highCount = report.summary?.high ?? 0;

  // ── SNS alert for high-severity findings ─────────────────────────────────
  if (highCount > 0) {
    const topFinding = report.findings?.[0];
    const emailMessage = `
CodeGuard Security Scan Report

Repository: ${report.repo}
Total Findings: ${report.summary.total}
High Severity:   ${report.summary.high}
Medium Severity: ${report.summary.medium}
Low Severity:    ${report.summary.low}

Most Critical Finding
---------------------
Severity:    ${topFinding?.severity ?? "N/A"}
Type:        ${topFinding?.type ?? "N/A"}
Location:    ${topFinding?.file ?? "N/A"}${topFinding?.line ? ` (Line ${topFinding.line})` : ""}
Description: ${topFinding?.message ?? "No description available"}

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

  // ── GitHub PR comment (only when triggered by a pull_request event) ───────
  if (prNumber) {
    const token = await getGithubToken();
    if (!token) {
      console.warn("No GitHub token available — skipping PR comment");
    } else {
      const [owner, repo] = report.repo.split("/");
      const topIssue = report.findings?.[0]?.message ?? "No findings";

      const comment = `## CodeGuard Scan Results

**Repository:** ${report.repo}

| Severity | Count |
|----------|-------|
| High     | ${report.summary?.high ?? 0} |
| Medium   | ${report.summary?.medium ?? 0} |
| Low      | ${report.summary?.low ?? 0} |
| **Total**| **${report.summary?.total ?? 0}** |

**Top Issue:** ${topIssue}

${highCount > 0 ? "⚠️ **Action required: high-severity vulnerabilities detected. Please remediate before merging.**" : "✅ No high-severity findings. Safe to merge."}
`;

      await postGitHubComment(owner, repo, prNumber, comment, token).catch((e) =>
        console.error("GitHub PR comment failed:", e.message)
      );

      console.log(`PR comment posted: repo=${report.repo} pr=${prNumber}`);
    }
  } else {
    console.log(`No prNumber in metadata — skipping PR comment (push event)`);
  }

  return { statusCode: 200, jobId, prNumber, highCount };
};
