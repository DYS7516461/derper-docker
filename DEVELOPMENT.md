# 开发文档

本页面向开发者：镜像构建、GitHub Actions 发版、Secrets 配置与本地测试。普通用户请阅读 [README.md](README.md)。

## 目录

- [仓库结构](#仓库结构)
- [镜像构建](#镜像构建)
- [GitHub Actions 发布](#github-actions-发布)
- [本地测试构建](#本地测试构建)
- [运行测试](#运行测试)

## 仓库结构

```text
derper-docker/
├── Dockerfile
├── docker-compose.yml
├── docker-compose.bridge.yml
├── docker-compose.bridge-manual.yml
├── docker-compose.manual-cert.yml
├── docker-compose.verify-clients.yml
├── install.sh
├── tests/
├── .env.example
├── .github/workflows/build.yml
├── README.md
└── LICENSE
```

## 镜像构建

`Dockerfile` 使用多阶段构建：

1. `golang:1.26-bookworm` 编译 `tailscale.com/cmd/derper@${TAILSCALE_VERSION}`（`GOTOOLCHAIN=auto`，Tailscale 要求更高 Go 版本时自动切换）。
2. `debian:bookworm-slim` 作为运行镜像，只安装 `ca-certificates` 并复制 `derper` 二进制。

默认版本是：

```dockerfile
ARG TAILSCALE_VERSION=v1.86.2
```

GitHub Actions 会在构建时通过 `--build-arg TAILSCALE_VERSION=...` 覆盖它。

## GitHub Actions 发布

工作流文件：`.github/workflows/build.yml`

支持三种触发方式：

- 推送 Git Tag，例如 `v1.86.2`。
- 在 GitHub Actions 页面手动运行，并输入 `tailscale_version`。
- 定时自动检查（每 6 小时）：检测 Tailscale 官方最新稳定版，若 GHCR 尚未发布该版本，
  自动构建并推送到 GHCR、阿里云 ACR、Docker Hub，同时更新 `latest`。

发布 tag 时会构建：

```text
linux/amd64
linux/arm64
```

并推送：

```text
ghcr.io/<owner>/<repo>:v1.86.2
ghcr.io/<owner>/<repo>:latest
registry.cn-hangzhou.aliyuncs.com/<namespace>/derper:v1.86.2
registry.cn-hangzhou.aliyuncs.com/<namespace>/derper:latest
docker.io/<dockerhub-namespace>/<dockerhub-image>:v1.86.2
docker.io/<dockerhub-namespace>/<dockerhub-image>:latest
```

任何一次构建（tag 推送、手动运行、定时自动检测）都会同时更新并推送 `latest` 标签到已配置的镜像仓库。

### GitHub Secrets

GHCR 使用 GitHub Actions 内置的 `GITHUB_TOKEN`，仓库已经配置：

```text
permissions:
  packages: write
```

不要手动创建名为 `GITHUB_TOKEN` 的 Secret。`GITHUB_TOKEN` 是 GitHub Actions 的内置 token，GitHub 不允许用户创建以 `GITHUB_` 开头的 Secret。

通常不需要为 GHCR 额外配置 Personal Access Token；只有推送 Docker Hub 或阿里云 ACR 时才需要配置下面的额外变量和 Secret。

如果要推送 Docker Hub，需要配置 Repository Variables：

```text
DOCKERHUB_NAMESPACE=your-dockerhub-namespace
DOCKERHUB_IMAGE=derper
```

`DOCKERHUB_IMAGE` 可选，不配置时默认使用 `derper`。

还需要配置 Repository Secrets：

```text
DOCKERHUB_USERNAME=your-dockerhub-username
DOCKERHUB_TOKEN=your-dockerhub-token
```

建议使用 Docker Hub Access Token，不要直接使用账号密码。

如果要推送阿里云 ACR，需要在 GitHub Repository Settings -> Secrets and variables -> Actions 里配置：

```text
ALIYUN_REGISTRY=registry.cn-hangzhou.aliyuncs.com
ALIYUN_NAMESPACE=your-namespace
ALIYUN_USERNAME=your-acr-username
ALIYUN_PASSWORD=your-acr-password
```

建议使用阿里云 ACR 的访问凭证，不要直接使用主账号密码。

如果没有配置这些 ACR secrets，workflow 会继续推送 GHCR 和已启用的其他仓库，只跳过 ACR。

如果没有完整配置 Docker Hub 的 namespace、username 和 token，workflow 会跳过 Docker Hub，不影响 GHCR / ACR。

### 发版流程

```bash
git tag v1.86.2
git push origin v1.86.2
```

之后 GitHub Actions 会自动构建并推送镜像。

## 本地测试构建

如果本机安装了 Docker，可以手动构建：

```bash
docker build --build-arg TAILSCALE_VERSION=v1.86.2 -t derper:local .
```

如果本机安装了 Docker Compose，可以检查配置：

```bash
docker compose --env-file .env.example config
docker compose -f docker-compose.bridge.yml --env-file .env.example config
```


## 运行测试

仓库自带 shell 测试套件（WSL / Linux 环境）：

```bash
bash tests/install_test.sh
```

覆盖安装脚本的配置生成、网络模式选择、证书模式组合与端口校验等场景。
