//
// Copyright 2020 Pixar
//
// Licensed under the Apache License, Version 2.0 (the "Apache License")
// with the following modification; you may not use this file except in
// compliance with the Apache License and the following modification to it:
// Section 6. Trademarks. is deleted and replaced with:
//
// 6. Trademarks. This License does not grant permission to use the trade
//    names, trademarks, service marks, or product names of the Licensor
//    and its affiliates, except as required to comply with Section 4(c) of
//    the License and to reproduce the content of the NOTICE file.
//
// You may obtain a copy of the Apache License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the Apache License with the above modification is
// distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied. See the Apache License for the specific
// language governing permissions and limitations under the Apache License.
//
#include "pxr/imaging/hgi/graphicsCmdsDesc.h"
#include "pxr/imaging/hgiMetal/buffer.h"
#include "pxr/imaging/hgiMetal/conversions.h"
#include "pxr/imaging/hgiMetal/diagnostic.h"
#include "pxr/imaging/hgiMetal/graphicsCmds.h"
#include "pxr/imaging/hgiMetal/hgi.h"
#include "pxr/imaging/hgiMetal/graphicsPipeline.h"
#include "pxr/imaging/hgiMetal/resourceBindings.h"
#include "pxr/imaging/hgiMetal/texture.h"

#include "pxr/base/arch/defines.h"

PXR_NAMESPACE_OPEN_SCOPE

HgiMetalGraphicsCmds::HgiMetalGraphicsCmds(
    HgiMetal* hgi,
    HgiGraphicsCmdsDesc const& desc)
    : HgiGraphicsCmds()
    , _hgi(hgi)
    , _renderPassDescriptor(nil)
    , _encoder(nil)
    , _argumentBuffer(nil)
    , _descriptor(desc)
    , _primitiveType(HgiPrimitiveTypeTriangleList)
    , _primitiveIndexSize(0)
    , _debugLabel(nil)
    , _viewportSet(false)
{
    TF_VERIFY(desc.colorTextures.size() == desc.colorAttachmentDescs.size());
    
    if (!desc.colorResolveTextures.empty() &&
            desc.colorResolveTextures.size() !=
                desc.colorTextures.size()) {
        TF_CODING_ERROR("color and resolve texture count mismatch.");
        return;
    }

    if (desc.depthResolveTexture && !desc.depthTexture) {
        TF_CODING_ERROR("DepthResolve texture without depth texture.");
        return;
    }
    
    static const size_t _maxStepFunctionDescs = 4;
    _vertexBufferStepFunctionDescs.reserve(_maxStepFunctionDescs);
    _patchBaseVertexBufferStepFunctionDescs.reserve(_maxStepFunctionDescs);

    _renderPassDescriptor = [[MTLRenderPassDescriptor alloc] init];

    // Color attachments
    bool resolvingColor = !desc.colorResolveTextures.empty();
    bool hasClear = false;
    for (size_t i=0; i<desc.colorAttachmentDescs.size(); i++) {
        HgiAttachmentDesc const &hgiColorAttachment =
            desc.colorAttachmentDescs[i];
        MTLRenderPassColorAttachmentDescriptor *metalColorAttachment =
            _renderPassDescriptor.colorAttachments[i];

        if (hgiColorAttachment.loadOp == HgiAttachmentLoadOpClear) {
            hasClear = true;
        }
        
        if (@available(macos 100.100, ios 8.0, *)) {
            metalColorAttachment.loadAction = MTLLoadActionLoad;
        }
        else {
            metalColorAttachment.loadAction =
                HgiMetalConversions::GetAttachmentLoadOp(
                    hgiColorAttachment.loadOp);
        }

        metalColorAttachment.storeAction =
            HgiMetalConversions::GetAttachmentStoreOp(
                hgiColorAttachment.storeOp);
        if (hgiColorAttachment.loadOp == HgiAttachmentLoadOpClear) {
            GfVec4f const& clearColor = hgiColorAttachment.clearValue;
            metalColorAttachment.clearColor =
                MTLClearColorMake(
                    clearColor[0], clearColor[1], clearColor[2], clearColor[3]);
        }
        
        HgiMetalTexture *colorTexture =
            static_cast<HgiMetalTexture*>(desc.colorTextures[i].Get());

        TF_VERIFY(
            colorTexture->GetDescriptor().format == hgiColorAttachment.format);
        metalColorAttachment.texture = colorTexture->GetTextureId();
        
        if (resolvingColor) {
            HgiMetalTexture *resolveTexture =
                static_cast<HgiMetalTexture*>(desc.colorResolveTextures[i].Get());

            metalColorAttachment.resolveTexture =
                resolveTexture->GetTextureId();

            if (hgiColorAttachment.storeOp == HgiAttachmentStoreOpStore) {
                metalColorAttachment.storeAction =
                    MTLStoreActionStoreAndMultisampleResolve;
            }
            else {
                metalColorAttachment.storeAction =
                    MTLStoreActionMultisampleResolve;
            }
        }
    }

    // Depth attachment
    if (desc.depthTexture) {
        HgiAttachmentDesc const &hgiDepthAttachment =
            desc.depthAttachmentDesc;
        MTLRenderPassDepthAttachmentDescriptor *metalDepthAttachment =
            _renderPassDescriptor.depthAttachment;

        if (hgiDepthAttachment.loadOp == HgiAttachmentLoadOpClear) {
            hasClear = true;
        }

        metalDepthAttachment.loadAction =
            HgiMetalConversions::GetAttachmentLoadOp(
                hgiDepthAttachment.loadOp);
        metalDepthAttachment.storeAction =
            HgiMetalConversions::GetAttachmentStoreOp(
                hgiDepthAttachment.storeOp);
        
        metalDepthAttachment.clearDepth = hgiDepthAttachment.clearValue[0];
        
        HgiMetalTexture *depthTexture =
            static_cast<HgiMetalTexture*>(desc.depthTexture.Get());
        
        TF_VERIFY(
            depthTexture->GetDescriptor().format == hgiDepthAttachment.format);
        metalDepthAttachment.texture = depthTexture->GetTextureId();
        
        if (desc.depthResolveTexture) {
            HgiMetalTexture *resolveTexture =
                static_cast<HgiMetalTexture*>(desc.depthResolveTexture.Get());

            metalDepthAttachment.resolveTexture =
                resolveTexture->GetTextureId();
            
            if (hgiDepthAttachment.storeOp == HgiAttachmentStoreOpStore) {
                metalDepthAttachment.storeAction =
                    MTLStoreActionStoreAndMultisampleResolve;
            }
            else {
                metalDepthAttachment.storeAction =
                    MTLStoreActionMultisampleResolve;
            }
        }
    }
    
    if (hasClear) {
        _CreateEncoder();
        _CreateArgumentBuffer();
    }
}

HgiMetalGraphicsCmds::~HgiMetalGraphicsCmds()
{
    TF_VERIFY(_encoder == nil, "Encoder created, but never commited.");
    
    [_renderPassDescriptor release];
    if (_debugLabel) {
        [_debugLabel release];
    }
}

void
HgiMetalGraphicsCmds::_CreateEncoder()
{
    if (!_encoder) {
        _encoder = [
            _hgi->GetPrimaryCommandBuffer(this, false)
            renderCommandEncoderWithDescriptor:_renderPassDescriptor];
        
        if (_debugLabel) {
            [_encoder pushDebugGroup:_debugLabel];
            [_debugLabel release];
            _debugLabel = nil;
        }
        if (_viewportSet) {
            [_encoder setViewport:_viewport];
    }
    }
}

void
HgiMetalGraphicsCmds::_CreateArgumentBuffer()
{
    if (!_argumentBuffer) {
        _argumentBuffer = _hgi->GetArgBuffer();
    }
}

void
HgiMetalGraphicsCmds::_SyncArgumentBuffer()
{
    if (_argumentBuffer) {
        if (_argumentBuffer.storageMode != MTLStorageModeShared &&
            [_argumentBuffer respondsToSelector:@selector(didModifyRange:)]) {
            NSRange range = NSMakeRange(0, _argumentBuffer.length);

            ARCH_PRAGMA_PUSH
            ARCH_PRAGMA_INSTANCE_METHOD_NOT_FOUND
            [_argumentBuffer didModifyRange:range];
            ARCH_PRAGMA_POP
        }
        _argumentBuffer = nil;
    }
}

void
HgiMetalGraphicsCmds::SetViewport(GfVec4i const& vp)
{
    double x = vp[0];
    double y = vp[1];
    double w = vp[2];
    double h = vp[3];
    // Viewport is inverted in the y. Along with the front face winding order
    // being inverted.
    // This combination allows us to emulate the OpenGL coordinate space on
    // Metal
    if (_encoder) {
        [_encoder setViewport:(MTLViewport){x, h-y, w, -h, 0.0, 1.0}];
    }
    else {
        _viewport = (MTLViewport){x, h-y, w, -h, 0.0, 1.0};
    }
    _viewportSet = true;
}

void
HgiMetalGraphicsCmds::SetScissor(GfVec4i const& sc)
{
    uint32_t x = sc[0];
    uint32_t y = sc[1];
    uint32_t w = sc[2];
    uint32_t h = sc[3];
    
    _CreateEncoder();
    
    [_encoder setScissorRect:(MTLScissorRect){x, y, w, h}];
}

void
HgiMetalGraphicsCmds::BindPipeline(HgiGraphicsPipelineHandle pipeline)
{
    _CreateEncoder();

    _primitiveType = pipeline->GetDescriptor().primitiveType;
    _primitiveIndexSize =
        pipeline->GetDescriptor().tessellationState.primitiveIndexSize;

    _InitVertexBufferStepFunction(pipeline.Get());

    if (HgiMetalGraphicsPipeline* p =
        static_cast<HgiMetalGraphicsPipeline*>(pipeline.Get())) {
        p->BindPipeline(_encoder);
    }
}

void
HgiMetalGraphicsCmds::BindResources(HgiResourceBindingsHandle r)
{
    _CreateEncoder();
    _CreateArgumentBuffer();

    if (HgiMetalResourceBindings* rb=
        static_cast<HgiMetalResourceBindings*>(r.Get()))
    {
        rb->BindResources(_hgi, _encoder, _argumentBuffer);
    }
}

void
HgiMetalGraphicsCmds::SetConstantValues(
    HgiGraphicsPipelineHandle pipeline,
    HgiShaderStage stages,
    uint32_t bindIndex,
    uint32_t byteSize,
    const void* data)
{
    _CreateArgumentBuffer();

    HgiMetalResourceBindings::SetConstantValues(
        _argumentBuffer, stages, bindIndex, byteSize, data);
}

void
HgiMetalGraphicsCmds::BindVertexBuffers(
    uint32_t firstBinding,
    HgiBufferHandleVector const& vertexBuffers,
    std::vector<uint32_t> const& byteOffsets)
{
    TF_VERIFY(byteOffsets.size() == vertexBuffers.size());

    _CreateEncoder();

    for (size_t i=0; i<vertexBuffers.size(); i++) {
        HgiBufferHandle bufHandle = vertexBuffers[i];
        HgiMetalBuffer* buf = static_cast<HgiMetalBuffer*>(bufHandle.Get());
        HgiBufferDesc const& desc = buf->GetDescriptor();

        uint32_t const byteOffset = byteOffsets[i];
        uint32_t const bindingIndex = firstBinding + i;

        TF_VERIFY(desc.usage & HgiBufferUsageVertex);
        
        [_encoder setVertexBuffer:buf->GetBufferId()
                           offset:byteOffset
                          atIndex:bindingIndex];

        _BindVertexBufferStepFunction(byteOffset, bindingIndex);
    }
}

void
HgiMetalGraphicsCmds::_InitVertexBufferStepFunction(
    HgiGraphicsPipeline const * pipeline)
{
    HgiGraphicsPipelineDesc const & descriptor = pipeline->GetDescriptor();

    _vertexBufferStepFunctionDescs.clear();
    _patchBaseVertexBufferStepFunctionDescs.clear();

    for (size_t index = 0; index < descriptor.vertexBuffers.size(); index++) {
        auto const & vbo = descriptor.vertexBuffers[index];
        if (vbo.vertexStepFunction ==
                    HgiVertexBufferStepFunctionPerDrawCommand) {
            _vertexBufferStepFunctionDescs.emplace_back(
                        index, 0, vbo.vertexStride);
        } else if (vbo.vertexStepFunction ==
                    HgiVertexBufferStepFunctionPerPatchControlPoint) {
            _patchBaseVertexBufferStepFunctionDescs.emplace_back(
                index, 0, vbo.vertexStride);
        }
    }
}

void
HgiMetalGraphicsCmds::_BindVertexBufferStepFunction(
    uint32_t byteOffset,
    uint32_t bindingIndex)
{
    for (auto & stepFunction : _vertexBufferStepFunctionDescs) {
        if (stepFunction.bindingIndex == bindingIndex) {
            stepFunction.byteOffset = byteOffset;
        }
    }
    for (auto & stepFunction : _patchBaseVertexBufferStepFunctionDescs) {
        if (stepFunction.bindingIndex == bindingIndex) {
            stepFunction.byteOffset = byteOffset;
        }
    }
}

void
HgiMetalGraphicsCmds::_SetVertexBufferStepFunctionOffsets(
    id<MTLRenderCommandEncoder> encoder,
    uint32_t baseInstance)
{
    for (auto const & stepFunction : _vertexBufferStepFunctionDescs) {
        uint32_t const offset = stepFunction.vertexStride * baseInstance +
                                stepFunction.byteOffset;

        [encoder setVertexBufferOffset:offset
                               atIndex:stepFunction.bindingIndex];
     }
}

void
HgiMetalGraphicsCmds::_SetPatchBaseVertexBufferStepFunctionOffsets(
    id<MTLRenderCommandEncoder> encoder,
    uint32_t baseVertex)
{
    for (auto const & stepFunction : _patchBaseVertexBufferStepFunctionDescs) {
        uint32_t const offset = stepFunction.vertexStride * baseVertex +
                                stepFunction.byteOffset;

        [encoder setVertexBufferOffset:offset
                               atIndex:stepFunction.bindingIndex];
    }
}

void
HgiMetalGraphicsCmds::Draw(
    uint32_t vertexCount,
    uint32_t baseVertex,
    uint32_t instanceCount,
    uint32_t baseInstance)
{
    _CreateEncoder();
    _SyncArgumentBuffer();

    MTLPrimitiveType type=HgiMetalConversions::GetPrimitiveType(_primitiveType);

    _SetVertexBufferStepFunctionOffsets(_encoder, baseInstance);

    if (_primitiveType == HgiPrimitiveTypePatchList) {
        const NSUInteger controlPointCount = _primitiveIndexSize;
        [_encoder drawPatches:controlPointCount
                   patchStart:0
                   patchCount:vertexCount/controlPointCount
             patchIndexBuffer:NULL
       patchIndexBufferOffset:0
                instanceCount:instanceCount
                 baseInstance:baseInstance];
    } else {
        if (instanceCount == 1) {
            [_encoder drawPrimitives:type
                         vertexStart:baseVertex
                         vertexCount:vertexCount];
        } else {
            [_encoder drawPrimitives:type
                         vertexStart:baseVertex
                         vertexCount:vertexCount
                       instanceCount:instanceCount
                        baseInstance:baseInstance];
        }
    }

    _hasWork = true;
}

void
HgiMetalGraphicsCmds::DrawIndirect(
    HgiBufferHandle const& drawParameterBuffer,
    uint32_t drawBufferByteOffset,
    uint32_t drawCount,
    uint32_t stride)
{
    _CreateEncoder();
    _SyncArgumentBuffer();

    HgiMetalBuffer* drawBuf =
        static_cast<HgiMetalBuffer*>(drawParameterBuffer.Get());

    MTLPrimitiveType type=HgiMetalConversions::GetPrimitiveType(_primitiveType);

    if (_primitiveType == HgiPrimitiveTypePatchList) {
        const NSUInteger controlPointCount = _primitiveIndexSize;
        for (uint32_t i = 0; i < drawCount; i++) {
            _SetVertexBufferStepFunctionOffsets(_encoder, i);

            const uint32_t bufferOffset = drawBufferByteOffset
                                        + (i * stride);
            [_encoder drawPatches:controlPointCount
                 patchIndexBuffer:NULL
           patchIndexBufferOffset:0
                   indirectBuffer:drawBuf->GetBufferId()
             indirectBufferOffset:bufferOffset];
        }
    }
    else {
        for (uint32_t i = 0; i < drawCount; i++) {
            _SetVertexBufferStepFunctionOffsets(_encoder, i);

            const uint32_t bufferOffset = drawBufferByteOffset
                                        + (i * stride);
            [_encoder drawPrimitives:type
                      indirectBuffer:drawBuf->GetBufferId()
                indirectBufferOffset:bufferOffset];
        }
    }
}

void
HgiMetalGraphicsCmds::DrawIndexed(
    HgiBufferHandle const& indexBuffer,
    uint32_t indexCount,
    uint32_t indexBufferByteOffset,
    uint32_t baseVertex,
    uint32_t instanceCount,
    uint32_t baseInstance)
{
    _CreateEncoder();
    _SyncArgumentBuffer();

    HgiMetalBuffer* indexBuf = static_cast<HgiMetalBuffer*>(indexBuffer.Get());

    MTLPrimitiveType type=HgiMetalConversions::GetPrimitiveType(_primitiveType);

    _SetVertexBufferStepFunctionOffsets(_encoder, baseInstance);

    if (_primitiveType == HgiPrimitiveTypePatchList) {
        const NSUInteger controlPointCount = _primitiveIndexSize;

        _SetPatchBaseVertexBufferStepFunctionOffsets(_encoder, baseVertex);

        [_encoder drawIndexedPatches:controlPointCount
                          patchStart:indexBufferByteOffset / sizeof(uint32_t)
                          patchCount:indexCount
                    patchIndexBuffer:nil
              patchIndexBufferOffset:0
             controlPointIndexBuffer:indexBuf->GetBufferId()
       controlPointIndexBufferOffset:0
                       instanceCount:instanceCount
                        baseInstance:baseInstance];
    } else {
        [_encoder drawIndexedPrimitives:type
                             indexCount:indexCount
                              indexType:MTLIndexTypeUInt32
                            indexBuffer:indexBuf->GetBufferId()
                      indexBufferOffset:indexBufferByteOffset
                          instanceCount:instanceCount
                             baseVertex:baseVertex
                           baseInstance:baseInstance];
    }

    _hasWork = true;
}

void
HgiMetalGraphicsCmds::DrawIndexedIndirect(
    HgiBufferHandle const& indexBuffer,
    HgiBufferHandle const& drawParameterBuffer,
    uint32_t drawBufferByteOffset,
    uint32_t drawCount,
    uint32_t stride,
    std::vector<uint32_t> const& drawParameterBufferUInt32,
    uint32_t patchBaseVertexByteOffset)
{
    _CreateEncoder();
    _SyncArgumentBuffer();
    
    id<MTLBuffer> indexBufferId =
        static_cast<HgiMetalBuffer*>(indexBuffer.Get())->GetBufferId();
    id<MTLBuffer> drawBufferId =
        static_cast<HgiMetalBuffer*>(drawParameterBuffer.Get())->GetBufferId();

    MTLPrimitiveType type =
        HgiMetalConversions::GetPrimitiveType(_primitiveType);

    if (_primitiveType == HgiPrimitiveTypePatchList) {
        const NSUInteger controlPointCount = _primitiveIndexSize;
        
        for (uint32_t i = 0; i < drawCount; i++) {
            _SetVertexBufferStepFunctionOffsets(_encoder, i);

            const uint32_t baseVertexIndex =
                (patchBaseVertexByteOffset +
                 i * stride) / sizeof(uint32_t);
            const uint32_t baseVertex =
                drawParameterBufferUInt32[baseVertexIndex];

            _SetPatchBaseVertexBufferStepFunctionOffsets(
                _encoder, baseVertex);

            const uint32_t bufferOffset = drawBufferByteOffset
                                        + (i * stride);
            [_encoder drawIndexedPatches:controlPointCount
                        patchIndexBuffer:nil
                  patchIndexBufferOffset:0
                 controlPointIndexBuffer:indexBufferId
           controlPointIndexBufferOffset:0
                          indirectBuffer:drawBufferId
                    indirectBufferOffset:bufferOffset];
        }
    }
    else {
        for (uint32_t i = 0; i < drawCount; i++) {
            _SetVertexBufferStepFunctionOffsets(_encoder, i);

            const uint32_t bufferOffset = drawBufferByteOffset
                                        + (i * stride);
            [_encoder drawIndexedPrimitives:type
                                  indexType:MTLIndexTypeUInt32
                                indexBuffer:indexBufferId
                          indexBufferOffset:0
                             indirectBuffer:drawBufferId
                       indirectBufferOffset:bufferOffset];
        }
    }
}

void
HgiMetalGraphicsCmds::PushDebugGroup(const char* label)
{
    if (!HgiMetalDebugEnabled()) {
        return;
    }

    if (_encoder) {
        HGIMETAL_DEBUG_PUSH_GROUP(_encoder, label)
    }
    else {
        _debugLabel = [@(label) copy];
    }
}

void
HgiMetalGraphicsCmds::PopDebugGroup()
{
    if (_encoder) {
        HGIMETAL_DEBUG_POP_GROUP(_encoder);
    }
    if (_debugLabel) {
        [_debugLabel release];
        _debugLabel = nil;
    }
}

void
HgiMetalGraphicsCmds::MemoryBarrier(HgiMemoryBarrier barrier)
{
    TF_VERIFY(barrier==HgiMemoryBarrierAll, "Unknown barrier");

    MTLBarrierScope scope =
        MTLBarrierScopeBuffers |
        MTLBarrierScopeTextures |
        MTLBarrierScopeRenderTargets;

    MTLRenderStages srcStages = MTLRenderStageVertex | MTLRenderStageFragment;
    MTLRenderStages dstStages = MTLRenderStageVertex | MTLRenderStageFragment;

    [_encoder memoryBarrierWithScope:scope
                         afterStages:srcStages
                         beforeStages:dstStages];
}

static
HgiMetal::CommitCommandBufferWaitType
_ToHgiMetal(const HgiSubmitWaitType wait)
{
    switch(wait) {
        case HgiSubmitWaitTypeNoWait:
            return HgiMetal::CommitCommandBuffer_NoWait;
        case HgiSubmitWaitTypeWaitUntilCompleted:
            return HgiMetal::CommitCommandBuffer_WaitUntilCompleted;
    }

    TF_CODING_ERROR("Bad enum value for HgiSubmitWaitType");
    return HgiMetal::CommitCommandBuffer_WaitUntilCompleted;
}

bool
HgiMetalGraphicsCmds::_Submit(Hgi* hgi, HgiSubmitWaitType wait)
{
    if (_encoder) {
        [_encoder endEncoding];
        _encoder = nil;

        _hgi->CommitPrimaryCommandBuffer(_ToHgiMetal(wait));
    }

    _argumentBuffer = nil;

    return _hasWork;
}

PXR_NAMESPACE_CLOSE_SCOPE
