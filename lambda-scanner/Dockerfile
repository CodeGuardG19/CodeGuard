FROM public.ecr.aws/lambda/nodejs:18

WORKDIR ${LAMBDA_TASK_ROOT}

COPY package*.json ./
RUN npm install --omit=dev

COPY src/ ./src/
COPY sast-engine/ ./sast-engine/

CMD ["src/index.handler"]
