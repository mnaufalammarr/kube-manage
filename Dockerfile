# Base image with Node.js
FROM node:20-alpine

# Install bash, curl, ca-certificates and kubectl CLI
RUN apk add --no-cache bash curl ca-certificates && \
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Set working directory
WORKDIR /app

# Copy package files and install dependencies
COPY package*.json ./
RUN npm install --only=production

# Copy application source
COPY . .

# Ensure script permissions
RUN chmod +x scripts/kube-manage.sh

# Expose port
EXPOSE 3000

# Environment variables default
ENV PORT=3000
ENV NODE_ENV=production

# Start application
CMD ["node", "server/index.js"]
