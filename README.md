# DERPer Docker

用 GitHub Actions 自编译 DERPer Docker 镜像，并同时推送到 GHCR 和阿里云 ACR。服务器只需要 `docker compose pull` 和 `docker compose up -d`，不需要安装 Go、Docker Buildx 或在本机编译。

DERPer 来自 Tailscale 官方 Go 包：`tailscale.com/cmd/derper`。

## 仓库结构

```text
derper-docker/
├── Dockerfile
├── docker-compose.yml
├── docker-compose.host.yml
├── docker-compose.bridge.yml
├── .env.example
├── .github/workflows/build.yml
├── README.md
└── LICENSE
```

## 镜像构建

`Dockerfile` 使用多阶段构建：

1. `golang:1.25-bookworm` 编译 `tailscale.com/cmd/derper@${TAILSCALE_VERSION}`。
2. `debian:bookworm-slim` 作为运行镜像，只安装 `ca-certificates` 并复制 `derper` 二进制。

默认版本是：

```dockerfile
ARG TAILSCALE_VERSION=v1.86.2
```

GitHub Actions 会在构建时通过 `--build-arg TAILSCALE_VERSION=...` 覆盖它。

## GitHub Actions 发布

工作流文件：`.github/workflows/build.yml`

支持两种触发方式：

- 推送 Git Tag，例如 `v1.86.2`。
- 在 GitHub Actions 页面手动运行，并输入 `tailscale_version`。

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
```

手动运行时默认只推送输入的版本 tag；如果勾选 `push_latest`，也会推送 `latest`。

### GitHub Secrets

GHCR 使用 `GHCR_TOKEN`。请在 GitHub Repository Settings -> Secrets and variables -> Actions 里配置：

```text
GHCR_TOKEN=your-github-token
```

`GHCR_TOKEN` 可以使用 GitHub Personal Access Token，至少需要 `write:packages` 权限。如果仓库是私有仓库，通常还需要 `repo` 权限。

不要手动创建名为 `GITHUB_TOKEN` 的 Secret。`GITHUB_TOKEN` 是 GitHub Actions 的内置 token，GitHub 不允许用户创建以 `GITHUB_` 开头的 Secret。

如果要推送阿里云 ACR，需要在 GitHub Repository Settings -> Secrets and variables -> Actions 里配置：

```text
ALIYUN_REGISTRY=registry.cn-hangzhou.aliyuncs.com
ALIYUN_NAMESPACE=your-namespace
ALIYUN_USERNAME=your-acr-username
ALIYUN_PASSWORD=your-acr-password
```

建议使用阿里云 ACR 的访问凭证，不要直接使用主账号密码。

如果没有配置这些 ACR secrets，workflow 会继续推送 GHCR，只跳过 ACR。

### 发版流程

```bash
git tag v1.86.2
git push origin v1.86.2
```

之后 GitHub Actions 会自动构建并推送镜像。

## 服务器部署

复制环境变量模板：

```bash
cp .env.example .env
```

编辑 `.env`：

```dotenv
DERP_HOSTNAME=derp.example.com
DERPER_IMAGE=registry.cn-hangzhou.aliyuncs.com/your-namespace/derper:latest
TZ=Asia/Shanghai
```

默认使用 host 网络：

```bash
docker compose up -d
```

更新镜像：

```bash
docker compose pull
docker compose up -d
```

### Host 网络模式

默认 `docker-compose.yml` 和 `docker-compose.host.yml` 都使用 host 网络。适合 Linux 服务器，端口映射最少，STUN UDP 行为也更直接。

```bash
docker compose -f docker-compose.host.yml up -d
```

### Bridge 网络模式

如果你不能使用 host 网络，可以使用 bridge 模式：

```bash
docker compose -f docker-compose.bridge.yml up -d
```

默认映射：

```text
80/tcp    -> Let's Encrypt HTTP 验证
443/tcp   -> DERP HTTPS
3478/udp  -> STUN
```

Let's Encrypt 证书会保存在 Docker volume `derper-certs` 中，容器重建后不会丢失。

## DNS 和防火墙

请确保：

- `DERP_HOSTNAME` 的 A/AAAA 记录指向服务器公网 IP。
- TCP `80` 对公网开放，用于 Let's Encrypt HTTP 验证。
- TCP `443` 对公网开放，用于 DERP。
- UDP `3478` 对公网开放，用于 STUN。

如果服务器前面有安全组、防火墙或云厂商 ACL，需要同时放行这些端口。

## Tailscale 配置示例

在 tailnet policy file 中加入自定义 `derpMap`，示例：

```json
{
  "derpMap": {
    "Regions": {
      "901": {
        "RegionID": 901,
        "RegionCode": "custom-cn",
        "RegionName": "Custom China DERP",
        "Nodes": [
          {
            "Name": "901a",
            "RegionID": 901,
            "HostName": "derp.example.com",
            "DERPPort": 443,
            "STUNPort": 3478
          }
        ]
      }
    }
  }
}
```

把 `derp.example.com` 换成你的 `DERP_HOSTNAME`。

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

## 常见注意事项

- `latest` 适合个人服务器自动跟随最新发布；生产环境也可以固定到 `v1.86.2` 这类版本 tag。
- 首次启动时 DERPer 会根据 `--certmode=letsencrypt` 自动申请证书，前提是 DNS 和 TCP `80` 已经正确开放。
- DERP 协议会在 TLS 内部切换到自定义双向协议，不适合放在普通 HTTP 反向代理后面；推荐让 DERPer 直接监听公网 `443/tcp`。
- 国内服务器建议部署时使用阿里云 ACR 镜像地址，拉取会更稳定。
- 公共开源用户可以直接使用 GHCR 镜像地址。
