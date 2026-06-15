FROM public.ecr.aws/lambda/nodejs:18 AS builder

WORKDIR /var/task

COPY package.json ./
RUN npm install --omit=dev --ignore-scripts

# ── Production image ──────────────────────────────────────────────────────────
FROM public.ecr.aws/lambda/nodejs:18

WORKDIR /var/task

# Copy production dependencies from builder stage
COPY --from=builder /var/task/node_modules ./node_modules

# Copy source
COPY src/ ./src/

# Lambda entry point: src/index.handler
CMD ["src/index.handler"]
