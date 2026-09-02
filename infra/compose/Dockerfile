FROM node:22-bookworm@sha256:0557ac14e0d45d02ed563067b82856ca5e7aa3437fa28d98d4350ea9c3d9494a
# pnpm (the version package.json's `packageManager` names) is fetched once here, into a
# Corepack home the runtime user can read. Without this, every container start as
# `node` (whose cache is empty) downloads pnpm again, and one stalled download leaves
# api/worker/web hung before their command runs.
ENV COREPACK_HOME=/opt/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
WORKDIR /app
COPY package.json ./
RUN corepack enable && corepack install && chmod -R a+rX /opt/corepack
COPY . .
RUN pnpm install --frozen-lockfile
RUN pnpm --filter @authoritymax/db generate
RUN AUTHORITYMAX_ALLOW_DEV_SECRETS=1 pnpm --filter @authoritymax/web build
RUN install -d -m 750 -o node -g node /data /app/apps/web/node_modules/.vite-temp
ARG GIT_SHA
ENV NODE_ENV=production
ENV GIT_SHA=$GIT_SHA
EXPOSE 3100 5173 7091
USER node
CMD ["pnpm", "--filter", "@authoritymax/api", "start"]
