FROM node:20-bookworm-slim

WORKDIR /app

# mediasoup may need native build tooling during npm install.
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*

COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

ENV NODE_ENV=production \
  PORT=3000 \
  MEDIASOUP_LISTEN_IP=0.0.0.0 \
  MEDIASOUP_MIN_PORT=20000 \
  MEDIASOUP_MAX_PORT=29999

EXPOSE 3000
EXPOSE 20000-29999/udp

CMD ["npm", "start"]
