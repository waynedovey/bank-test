FROM registry.access.redhat.com/ubi9/nodejs-18:latest
WORKDIR /opt/app-root/src
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev
COPY . .
EXPOSE 8080
CMD ["npm","start"]
