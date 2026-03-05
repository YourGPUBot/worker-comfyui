#!/bin/bash
#
# Start script for RunPod ComfyUI Worker with Workflow-Specific R2 Model Mounting
# Mounts only the models needed for the specific workflow + common shared models
# Uses overlay pattern: _common/ first, then workflow-specific on top
# FALLBACK: If workflow folder doesn't exist, uses root-level model folders

set -e

echo "=========================================="
echo "ComfyUI Worker - Workflow Model Mount"
echo "=========================================="

# Configuration
R2_ENDPOINT="${R2_ENDPOINT:-https://38d27e0247b1a8b9aeb73d8ec4648262.r2.cloudflarestorage.com}"
R2_BUCKET="${R2_BUCKET:-comfyui-models}"
R2_ACCESS_KEY="${R2_ACCESS_KEY_ID}"
R2_SECRET_KEY="${R2_SECRET_ACCESS_KEY}"
MODEL_SET="${MODEL_SET:-flux2-faceswap}"  # Comma-separated list of workflows

# ComfyUI paths
COMFYUI_BASE="/comfyui"
MODEL_BASE="/runpod-volume/models"
CACHE_DIR="/tmp/s3fs-cache"

# Model subdirectories to mount
MODEL_TYPES="checkpoints clip clip_vision configs controlnet embeddings loras upscale_models vae unet diffusion_models text_encoders"

# Create credentials file for s3fs
setup_s3fs_credentials() {
    if [ -z "$R2_ACCESS_KEY" ] || [ -z "$R2_SECRET_KEY" ]; then
        echo "❌ ERROR: R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY must be set"
        exit 1
    fi
    
    echo "$R2_ACCESS_KEY:$R2_SECRET_KEY" > /etc/r2-credentials
    chmod 600 /etc/r2-credentials
    echo "✓ S3FS credentials configured"
}

# Create required directories
setup_directories() {
    echo "Creating model directories..."
    
    for model_type in $MODEL_TYPES; do
        mkdir -p "$MODEL_BASE/$model_type"
    done
    
    # Create cache directory for s3fs
    mkdir -p "$CACHE_DIR"
    
    echo "✓ Directories created"
}

# Mount a specific prefix from R2 bucket
# Usage: mount_s3fs_prefix <r2_prefix> <local_path> [description]
mount_s3fs_prefix() {
    local r2_prefix="$1"
    local local_path="$2"
    local description="${3:-$r2_prefix}"
    
    # Check if already mounted
    if mountpoint -q "$local_path" 2>/dev/null; then
        echo "  ✓ $description already mounted"
        return 0
    fi
    
    echo "  📦 Mounting $description..."
    
    # Build s3fs options
    local s3fs_opts=""
    s3fs_opts="$s3fs_opts -o passwd_file=/etc/r2-credentials"
    s3fs_opts="$s3fs_opts -o url=$R2_ENDPOINT"
    s3fs_opts="$s3fs_opts -o use_path_request_style"
    s3fs_opts="$s3fs_opts -o allow_other"
    s3fs_opts="$s3fs_opts -o umask=000"
    s3fs_opts="$s3fs_opts -o use_cache=$CACHE_DIR"
    s3fs_opts="$s3fs_opts -o enable_noobj_cache"
    s3fs_opts="$s3fs_opts -o max_stat_cache_size=100000"
    s3fs_opts="$s3fs_opts -o parallel_count=10"
    s3fs_opts="$s3fs_opts -o multipart_size=128"
    s3fs_opts="$s3fs_opts -o max_background=1000"
    s3fs_opts="$s3fs_opts -o dbglevel=warn"
    
    # Non-empty flag if prefix has content
    s3fs_opts="$s3fs_opts -o nonempty"
    
    if s3fs "${R2_BUCKET}:${r2_prefix}" "$local_path" $s3fs_opts 2>/dev/null; then
        echo "  ✓ $description mounted successfully"
        return 0
    else
        echo "  ⚠️  $description mount failed or empty (skipped)"
        return 1
    fi
}

# NEW: Mount models with fallback hierarchy
# Tries: 1) workflow/model_type, 2) model_type (root), 3) _common/model_type
mount_model_with_fallback() {
    local workflow="$1"
    local model_type="$2"
    local local_path="$MODEL_BASE/$model_type"
    
    # Already mounted? Skip
    if mountpoint -q "$local_path" 2>/dev/null; then
        return 0
    fi
    
    # Try 1: Workflow-specific folder (e.g., flux2-faceswap/loras/)
    if mount_s3fs_prefix "$workflow/$model_type" "$local_path" "$workflow/$model_type"; then
        return 0
    fi
    
    # Try 2: Root-level folder (e.g., loras/) - LEGACY FALLBACK
    if mount_s3fs_prefix "$model_type" "$local_path" "$model_type (root)"; then
        return 0
    fi
    
    # Try 3: Common folder (e.g., _common/loras/)
    if mount_s3fs_prefix "_common/$model_type" "$local_path" "_common/$model_type"; then
        return 0
    fi
    
    # All failed
    return 1
}

# Mount workflow-specific models with hierarchical fallback
mount_workflow_models() {
    echo ""
    echo "Mounting workflow-specific models..."
    echo "MODEL_SET: $MODEL_SET"
    echo ""
    
    # Parse comma-separated list of workflows
    IFS=',' read -ra WORKFLOWS <<< "$MODEL_SET"
    
    for workflow in "${WORKFLOWS[@]}"; do
        workflow=$(echo "$workflow" | xargs)  # Trim whitespace
        
        if [ -z "$workflow" ] || [ "$workflow" = "none" ]; then
            continue
        fi
        
        echo ""
        echo "📂 Workflow: $workflow"
        echo "  Mount hierarchy: $workflow/ → root/ → _common/"
        
        local mounted=0
        local failed=0
        
        for model_type in $MODEL_TYPES; do
            if mount_model_with_fallback "$workflow" "$model_type"; then
                mounted=$((mounted + 1))
            else
                failed=$((failed + 1))
            fi
        done
        
        echo "  ✓ Mounted $mounted directories, $failed empty/missing"
    done
    
    echo ""
    echo "✓ Model mounting complete"
}

# Verify mounts and show what's available
verify_mounts() {
    echo ""
    echo "Verifying model mounts..."
    echo "--------------------------"
    
    local total_models=0
    local mounted_dirs=0
    
    for dir in "$MODEL_BASE"/*/; do
        if [ -d "$dir" ]; then
            local dir_name=$(basename "$dir")
            local count=$(find "$dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
            
            # Check if it's a mountpoint
            if mountpoint -q "$dir" 2>/dev/null; then
                echo "  📦 $dir_name: $count files (mounted)"
                mounted_dirs=$((mounted_dirs + 1))
            else
                echo "  💾 $dir_name: $count files (local)"
            fi
            
            total_models=$((total_models + count))
        fi
    done
    
    echo "--------------------------"
    echo "Mounted directories: $mounted_dirs"
    echo "Total models available: $total_models"
    
    # Check disk usage (should be minimal since models are mounted)
    echo ""
    echo "Disk usage:"
    df -h / | tail -1 | awk '{print "  Root: " $3 " used / " $2 " total (" $5 " full)"}'
    df -h /tmp 2>/dev/null | tail -1 | awk '{print "  /tmp: " $3 " used / " $2 " total (" $5 " full)"}' || echo "  /tmp: N/A"
    
    # Cache usage
    if [ -d "$CACHE_DIR" ]; then
        local cache_size=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)
        echo "  Cache: $cache_size"
    fi
}

# Setup libtcmalloc for better memory management
setup_tcmalloc() {
    local TCMALLOC="$(ldconfig -p | grep -Po "libtcmalloc.so.\d" | head -n 1)"
    if [ -n "$TCMALLOC" ]; then
        export LD_PRELOAD="$TCMALLOC"
        echo "✓ libtcmalloc enabled"
    fi
}

# Set ComfyUI-Manager to offline mode
set_manager_offline() {
    if command -v comfy-manager-set-mode &> /dev/null; then
        comfy-manager-set-mode offline || echo "⚠️  Could not set Manager to offline mode"
    fi
}

# Cleanup function for graceful shutdown
cleanup() {
    echo ""
    echo "Unmounting R2 buckets..."
    for mount in "$MODEL_BASE"/*/; do
        if mountpoint -q "$mount" 2>/dev/null; then
            umount "$mount" 2>/dev/null || true
        fi
    done
    echo "✓ Cleanup complete"
}

trap cleanup EXIT

# Main execution
main() {
    echo "Starting ComfyUI Worker with R2 Model Mount"
    echo "R2 Endpoint: $R2_ENDPOINT"
    echo "R2 Bucket: $R2_BUCKET"
    echo "Mount Hierarchy: workflow/ → root/ → _common/"
    echo ""
    
    # Setup
    setup_s3fs_credentials
    setup_directories
    
    # Mount models based on configuration
    mount_workflow_models
    
    verify_mounts
    setup_tcmalloc
    set_manager_offline
    
    # Start ComfyUI
    echo ""
    echo "=========================================="
    echo "Starting ComfyUI Server..."
    echo "=========================================="
    
    COMFY_LOG_LEVEL="${COMFY_LOG_LEVEL:-DEBUG}"
    
    if [ "$SERVE_API_LOCALLY" == "true" ]; then
        python -u "$COMFYUI_BASE/main.py" \
            --disable-auto-launch \
            --disable-metadata \
            --listen \
            --verbose "$COMFY_LOG_LEVEL" \
            --log-stdout &
        
        echo "Starting RunPod Handler (with local API)"
        python -u /handler.py --rp_serve_api --rp_api_host=0.0.0.0
    else
        python -u "$COMFYUI_BASE/main.py" \
            --disable-auto-launch \
            --disable-metadata \
            --verbose "$COMFY_LOG_LEVEL" \
            --log-stdout &
        
        echo "Starting RunPod Handler"
        python -u /handler.py
    fi
}

# Run main
main "$@"
