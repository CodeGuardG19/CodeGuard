FROM node:18-alpine AS builder

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --ignore-scripts

# ── Production image ──────────────────────────────────────────────────────────
FROM node:18-alpine

# Lambda Web Adapter is not used — we use the Lambda Node.js runtime directly
# via the AWS-provided base image handler interface.

WORKDIR /var/task

# Copy production dependencies from builder stage
COPY --from=builder /app/node_modules ./node_modules

# Copy source
COPY src/ ./src/

# Lambda entry point: src/index.handler
CMD ["src/index.handler"]
