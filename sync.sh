#!/bin/bash
set -eux # -u: 遇到未定义变量报错；-e: 任何命令失败立即退出；-x: 打印执行的命令
IMAGES_FILE="images.txt"

# 检查配置文件和镜像列表文件是否存在
if [ ! -f "$IMAGES_FILE" ]; then
    echo "Error: images.txt not found! Please create it with a list of images to sync."
    exit 1
fi


# 检查必要的配置变量是否已设置
if [ -z "$ACR_REGISTRY" ] || [ -z "$ACR_NAMESPACE" ]; then
    echo "Error: ACR_REGISTRY or ACR_NAMESPACE not set in github variables. Please check your config."
    exit 1
fi

# 设置目标架构，默认为 linux/amd64，如果需要 arm64 可通过环境变量覆盖，例如：export ARCH=linux/arm64
ARCH=${ARCH:-linux/arm64}
# 是否强制同步（忽略目标仓库已存在的检查），默认 false
FORCE_SYNC=${FORCE_SYNC:-false}

echo "Starting Docker image synchronization to ACR..."
echo "Target Registry: ${ACR_REGISTRY}"
echo "Target Namespace: ${ACR_NAMESPACE}"
echo "Target Architecture: ${ARCH}"
echo "-----------------------------------"

# 遍历 images.txt，逐行处理镜像
while IFS= read -r image; do
    # 跳过空行或以 # 开头的注释行
    if [[ -z "$image" || "$image" =~ ^# ]]; then
        continue
    fi

    echo "--- Processing image: ${image} ---"

    # 分离原始镜像的仓库名和标签
    # 例如：nginx:latest -> original_repo=nginx, original_tag=latest
    # 例如：jenkins/jenkins:lts -> original_repo=jenkins/jenkins, original_tag=lts
    original_repo=$(echo "$image" | cut -d ':' -f1)
    original_tag=$(echo "$image" | cut -d ':' -f2)

    acr_compatible_repo_name="${original_repo//\//-}"

    # 构造目标 ACR 完整镜像路径
    target_full_image_path="${ACR_REGISTRY}/${ACR_NAMESPACE}/${acr_compatible_repo_name}:${original_tag}"

    # 如果指定了非默认架构 (amd64)，建议给 tag 加上架构后缀，防止覆盖原有 amd64 镜像
    # 如果你确定要覆盖，可以不加后缀。这里为了演示，如果不覆盖，可以取消注释下面这行：
    # if [ "$ARCH" != "linux/amd64" ]; then target_full_image_path="${target_full_image_path}-arm64"; fi

    echo "Original image full path: ${image}"
    echo "Target ACR image full path: ${target_full_image_path}"

    # 检查阿里云仓库是否已有该tag
    # docker manifest inspect 命令用于检查远程 Registry 中的镜像是否存在。
    # 如果已经存在，则跳过本次同步，避免重复操作和不必要的流量消耗。
    if [ "$FORCE_SYNC" != "true" ] && docker manifest inspect "${target_full_image_path}" > /dev/null 2>&1; then
        echo "${target_full_image_path} 已存在于 ACR，跳过本次同步。"
        echo "-----------------------------------"
        continue # 跳过当前循环的后续步骤
    fi

    echo "Image ${target_full_image_path} not found in ACR (or force sync enabled). Proceeding with sync..."

    # 拉取原始镜像，指定架构
    echo "Pulling original image: ${image} with platform ${ARCH}..."
    docker pull --platform "${ARCH}" "${image}"

    # 打上阿里云 ACR 的标签
    echo "Tagging image ${image} to ${target_full_image_path}..."
    docker tag "${image}" "${target_full_image_path}"

    # 推送到阿里云 ACR
    echo "Pushing image ${target_full_image_path} to ACR..."
    docker push "${target_full_image_path}"

    # 清理本地拉取和打标签的镜像，释放 GitHub Actions Runner 的磁盘空间
    echo "Cleaning up local images..."
    # 使用 || true 即使删除失败也不会中断脚本，确保后续镜像能继续处理
    docker rmi "${image}" || true
    docker rmi "${target_full_image_path}" || true

    echo "Successfully synced: ${image} to ${target_full_image_path}"
    echo "-----------------------------------"

done < "$IMAGES_FILE"

echo "All specified images processed successfully."
echo "Synchronization process finished."
