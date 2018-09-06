/**
This module contains opengl based drawing buffer implementation.

To enable OpenGL support, build with version(USE_OPENGL);

Synopsis:
---
import beamui.graphics.gldrawbuf;
---

Copyright: Vadim Lopatin 2014-2017, dayllenger 2017-2018
License:   Boost License 1.0
Authors:   Vadim Lopatin
*/
module beamui.graphics.gldrawbuf;

import beamui.core.config;

static if (USE_OPENGL):
import beamui.core.functions;
import beamui.core.logger;
import beamui.core.math3d;
import beamui.graphics.colors;
import beamui.graphics.drawbuf;
import beamui.graphics.glsupport;

/// Drawing buffer - image container which allows to perform some drawing operations
class GLDrawBuf : DrawBuf
{
    protected int _w;
    protected int _h;

    this(int dx, int dy)
    {
        resize(dx, dy);
    }

    /// Returns current width
    override @property int width()
    {
        return _w;
    }
    /// Returns current height
    override @property int height()
    {
        return _h;
    }

    /// Reserved for hardware-accelerated drawing - begins drawing queue
    override void beforeDrawing()
    {
        _alpha = 0;
        glSupport.setOrthoProjection(Rect(0, 0, _w, _h), Rect(0, 0, _w, _h));
        glSupport.beforeRenderGUI();
    }

    /// Reserved for hardware-accelerated drawing - ends drawing queue
    override void afterDrawing()
    {
        glSupport.queue.flush();
        glSupport.flushGL();
    }

    /// Resize buffer
    override void resize(int width, int height)
    {
        _w = width;
        _h = height;
        resetClipping();
    }

    /// Draw custom OpenGL scene
    override void drawCustomOpenGLScene(Rect rc, OpenGLDrawableDelegate handler)
    {
        if (handler)
        {
            Rect windowRect = Rect(0, 0, width, height);
            glSupport.queue.flush();
            glSupport.setOrthoProjection(windowRect, rc);
            glSupport.clearDepthBuffer();
            handler(windowRect, rc);
            glSupport.setOrthoProjection(windowRect, windowRect);
        }
    }

    /// Fill the whole buffer with solid color (clipping is applied)
    override void fill(uint color)
    {
        if (hasClipping)
        {
            fillRect(_clipRect, color);
            return;
        }
        glSupport.queue.addSolidRect(Rect(0, 0, _w, _h), applyAlpha(color));
    }
    /// Fill rectangle with solid color (clipping is applied)
    override void fillRect(Rect rc, uint color)
    {
        color = applyAlpha(color);
        if (!isFullyTransparentColor(color) && applyClipping(rc))
            glSupport.queue.addSolidRect(rc, color);
    }

    /// Fill rectangle with a gradient (clipping is applied)
    override void fillGradientRect(Rect rc, uint color1, uint color2, uint color3, uint color4)
    {
        color1 = applyAlpha(color1);
        color2 = applyAlpha(color2);
        color3 = applyAlpha(color3);
        color4 = applyAlpha(color4);
        if (!(isFullyTransparentColor(color1) && isFullyTransparentColor(color3)) && applyClipping(rc))
            glSupport.queue.addGradientRect(rc, color1, color2, color3, color4);
    }

    /// Draw pixel at (x, y) with specified color (clipping is applied)
    override void drawPixel(int x, int y, uint color)
    {
        if (!_clipRect.isPointInside(x, y))
            return;
        color = applyAlpha(color);
        if (isFullyTransparentColor(color))
            return;
        glSupport.queue.addSolidRect(Rect(x, y, x + 1, y + 1), color);
    }
    /// Draw 8bit alpha image - usually font glyph using specified color (clipping is applied)
    override void drawGlyph(int x, int y, Glyph* glyph, uint color)
    {
        Rect dstrect = Rect(x, y, x + glyph.correctedBlackBoxX, y + glyph.blackBoxY);
        Rect srcrect = Rect(0, 0, glyph.correctedBlackBoxX, glyph.blackBoxY);
        color = applyAlpha(color);
        if (!isFullyTransparentColor(color) && applyClipping(dstrect, srcrect))
        {
            if (!glGlyphCache.isInCache(glyph.id))
                glGlyphCache.put(glyph);
            glGlyphCache.drawItem(glyph.id, dstrect, srcrect, color, null);
        }
    }
    /// Draw source buffer rectangle contents to destination buffer
    override void drawFragment(int x, int y, DrawBuf src, Rect srcrect)
    {
        Rect dstrect = Rect(x, y, x + srcrect.width, y + srcrect.height);
        if (applyClipping(dstrect, srcrect))
        {
            if (!glImageCache.isInCache(src.id))
                glImageCache.put(src);
            glImageCache.drawItem(src.id, dstrect, srcrect, applyAlpha(0xFFFFFF), 0, null);
        }
    }
    /// Draw source buffer rectangle contents to destination buffer rectangle applying rescaling
    override void drawRescaled(Rect dstrect, DrawBuf src, Rect srcrect)
    {
        if (applyClipping(dstrect, srcrect))
        {
            if (!glImageCache.isInCache(src.id))
                glImageCache.put(src);
            glImageCache.drawItem(src.id, dstrect, srcrect, applyAlpha(0xFFFFFF), 0, null);
        }
    }

    /// Draw line from point p1 to p2 with specified color
    override void drawLine(Point p1, Point p2, uint color)
    {
        if (!clipLine(_clipRect, p1, p2))
            return;
        glSupport.queue.addLine(Rect(p1, p2), color, color);
    }

    /// Draw filled triangle in float coordinates; clipping is already applied
    override protected void fillTriangleFClipped(PointF p1, PointF p2, PointF p3, uint color)
    {
        glSupport.queue.addTriangle(p1, p2, p3, color, color, color);
    }
}

enum MIN_TEX_SIZE = 64;
enum MAX_TEX_SIZE = 4096;
private int nearestPOT(int n)
{
    for (int i = MIN_TEX_SIZE; i <= MAX_TEX_SIZE; i *= 2)
    {
        if (n <= i)
            return i;
    }
    return MIN_TEX_SIZE;
}

private int correctTextureSize(int n)
{
    if (n < 16)
        return 16;
    version (POT_TEXTURE_SIZES)
    {
        return nearestPOT(n);
    }
    else
    {
        return n;
    }
}

/// Object deletion listener callback function type
void onObjectDestroyedCallback(uint pobject)
{
    glImageCache.onCachedObjectDeleted(pobject);
}

/// Object deletion listener callback function type
void onGlyphDestroyedCallback(uint pobject)
{
    glGlyphCache.onCachedObjectDeleted(pobject);
}

private __gshared GLImageCache glImageCache;
private __gshared GLGlyphCache glGlyphCache;

void initGLCaches()
{
    if (!glImageCache)
        glImageCache = new GLImageCache;
    if (!glGlyphCache)
        glGlyphCache = new GLGlyphCache;
}

void destroyGLCaches()
{
    eliminate(glImageCache);
    eliminate(glGlyphCache);
}

private abstract class GLCache
{
    static class GLCacheItem
    {
        @property GLCachePage page()
        {
            return _page;
        }

        uint _objectID;
        // image size
        Rect _rc;
        bool _deleted;

        this(GLCachePage page, uint objectID)
        {
            _page = page;
            _objectID = objectID;
        }

        private GLCachePage _page;
    }

    static abstract class GLCachePage
    {
        private
        {
            GLCache _cache;
            int _tdx;
            int _tdy;
            ColorDrawBuf _drawbuf;
            int _currentLine;
            int _nextLine;
            int _x;
            bool _closed;
            bool _needUpdateTexture;
            Tex2D _texture;
            int _itemCount;
        }

        this(GLCache cache, int dx, int dy)
        {
            _cache = cache;
            _tdx = correctTextureSize(dx);
            _tdy = correctTextureSize(dy);
            _itemCount = 0;
        }

        ~this()
        {
            eliminate(_drawbuf);
            eliminate(_texture);
        }

        final void updateTexture()
        {
            if (_drawbuf is null)
                return; // no draw buffer!!!
            if (_texture is null || _texture.ID == 0)
            {
                _texture = new Tex2D;
                Log.d("updateTexture - new texture id=", _texture.ID);
                if (!_texture.ID)
                    return;
            }
            // FIXME
            //             Log.d("updateTexture for cache page - setting image ",
            //                 _drawbuf.width, "x", _drawbuf.height,
            //                 " tex id = ", _texture ? _texture.ID : 0);
            uint* pixels = _drawbuf.scanLine(0);
            if (!glSupport.setTextureImage(_texture, _drawbuf.width, _drawbuf.height, cast(ubyte*)pixels))
            {
                eliminate(_texture);
                return;
            }
            _needUpdateTexture = false;
            if (_closed)
            {
                eliminate(_drawbuf);
            }
        }

        final GLCacheItem reserveSpace(uint objectID, int width, int height)
        {
            auto cacheItem = new GLCacheItem(this, objectID);
            if (_closed)
                return null;

            int spacer = (width == _tdx || height == _tdy) ? 0 : 1;

            // next line if necessary
            if (_x + width + spacer * 2 > _tdx)
            {
                // move to next line
                _currentLine = _nextLine;
                _x = 0;
            }
            // check if no room left for glyph height
            if (_currentLine + height + spacer * 2 > _tdy)
            {
                _closed = true;
                return null;
            }
            cacheItem._rc = Rect(_x + spacer, _currentLine + spacer, _x + width + spacer, _currentLine + height + spacer);
            if (height && width)
            {
                if (_nextLine < _currentLine + height + 2 * spacer)
                    _nextLine = _currentLine + height + 2 * spacer;
                if (!_drawbuf)
                {
                    _drawbuf = new ColorDrawBuf(_tdx, _tdy);
                    //_drawbuf.SetBackgroundColor(0x000000);
                    //_drawbuf.SetTextColor(0xFFFFFF);
                    _drawbuf.fill(0xFF000000);
                }
                _x += width + spacer;
                _needUpdateTexture = true;
            }
            _itemCount++;
            return cacheItem;
        }

        final int deleteItem(GLCacheItem item)
        {
            _itemCount--;
            return _itemCount;
        }

        final void close()
        {
            _closed = true;
            if (_needUpdateTexture)
                updateTexture();
        }
    }

    GLCacheItem[uint] _map;
    GLCachePage[] _pages;
    GLCachePage _activePage;
    int tdx;
    int tdy;

    final void removePage(GLCachePage page)
    {
        if (_activePage == page)
            _activePage = null;
        foreach (i; 0 .. _pages.length)
            if (_pages[i] == page)
            {
                _pages = _pages.remove(i);
                break;
            }
        destroy(page);
    }

    final void updateTextureSize()
    {
        if (!tdx)
        {
            // TODO
            tdx = tdy = 1024; //getMaxTextureSize();
            if (tdx > 1024)
                tdx = tdy = 1024;
        }
    }

    this()
    {
    }

    ~this()
    {
        clear();
    }
    /// Check if item is in cache
    final bool isInCache(uint obj)
    {
        if (obj in _map)
            return true;
        return false;
    }
    /// Clears cache
    final void clear()
    {
        eliminate(_pages);
        eliminate(_map);
    }
    /// Handle cached object deletion, mark as deleted
    final void onCachedObjectDeleted(uint objectID)
    {
        if (objectID in _map)
        {
            GLCacheItem item = _map[objectID];
            int itemsLeft = item.page.deleteItem(item);
            if (itemsLeft <= 0)
            {
                removePage(item.page);
            }
            _map.remove(objectID);
            destroy(item);
        }
    }
    /// Remove deleted items - remove page if contains only deleted items
    final void removeDeletedItems()
    {
        uint[] list;
        foreach (GLCacheItem item; _map)
        {
            if (item._deleted)
                list ~= item._objectID;
        }
        foreach (i; 0 .. list.length)
        {
            onCachedObjectDeleted(list[i]);
        }
    }
}

/// OpenGL texture cache for ColorDrawBuf objects
private class GLImageCache : GLCache
{
    static class GLImageCachePage : GLCachePage
    {
        this(GLImageCache cache, int dx, int dy)
        {
            super(cache, dx, dy);
            Log.v("created image cache page ", dx, "x", dy);
        }

        void convertPixelFormat(GLCacheItem item)
        {
            Rect rc = item._rc;
            if (rc.top > 0)
                rc.top--;
            if (rc.left > 0)
                rc.left--;
            if (rc.right < _tdx)
                rc.right++;
            if (rc.bottom < _tdy)
                rc.bottom++;
            for (int y = rc.top; y < rc.bottom; y++)
            {
                uint* row = _drawbuf.scanLine(y);
                for (int x = rc.left; x < rc.right; x++)
                {
                    uint cl = row[x];
                    // invert A
                    cl ^= 0xFF000000;
                    // swap R and B
                    uint r = (cl & 0x00FF0000) >> 16;
                    uint b = (cl & 0x000000FF) << 16;
                    row[x] = (cl & 0xFF00FF00) | r | b;
                }
            }
        }

        GLCacheItem addItem(DrawBuf buf)
        {
            GLCacheItem cacheItem = reserveSpace(buf.id, buf.width, buf.height);
            if (cacheItem is null)
                return null;
            buf.onDestroyCallback = &onObjectDestroyedCallback;
            _drawbuf.drawImage(cacheItem._rc.left, cacheItem._rc.top, buf);
            convertPixelFormat(cacheItem);
            _needUpdateTexture = true;
            return cacheItem;
        }

        void drawItem(GLCacheItem item, Rect dstrc, Rect srcrc, uint color, uint options, Rect* clip)
        {
            if (_needUpdateTexture)
                updateTexture();
            if (_texture && _texture.ID != 0)
            {
                int rx = dstrc.middlex;
                int ry = dstrc.middley;
                // convert coordinates to cached texture
                srcrc.offset(item._rc.left, item._rc.top);
                if (clip)
                {
                    int srcw = srcrc.width();
                    int srch = srcrc.height();
                    int dstw = dstrc.width();
                    int dsth = dstrc.height();
                    if (dstw)
                    {
                        srcrc.left += clip.left * srcw / dstw;
                        srcrc.right -= clip.right * srcw / dstw;
                    }
                    if (dsth)
                    {
                        srcrc.top += clip.top * srch / dsth;
                        srcrc.bottom -= clip.bottom * srch / dsth;
                    }
                    dstrc.left += clip.left;
                    dstrc.right -= clip.right;
                    dstrc.top += clip.top;
                    dstrc.bottom -= clip.bottom;
                }
                if (!dstrc.empty)
                    glSupport.queue.addTexturedRect(_texture, _tdx, _tdy, color, color, color,
                            color, srcrc, dstrc, true);
            }
        }
    }

    /// Put new object to cache
    void put(DrawBuf img)
    {
        updateTextureSize();
        GLCacheItem res = null;
        if (img.width <= tdx / 3 && img.height < tdy / 3)
        {
            // trying to reuse common page for small images
            if (_activePage is null)
            {
                _activePage = new GLImageCachePage(this, tdx, tdy);
                _pages ~= _activePage;
            }
            res = (cast(GLImageCachePage)_activePage).addItem(img);
            if (!res)
            {
                auto page = new GLImageCachePage(this, tdx, tdy);
                _pages ~= page;
                res = page.addItem(img);
                _activePage = page;
            }
        }
        else
        {
            // use separate page for big image
            auto page = new GLImageCachePage(this, img.width, img.height);
            _pages ~= page;
            res = page.addItem(img);
            page.close();
        }
        _map[img.id] = res;
    }
    /// Draw cached item
    void drawItem(uint objectID, Rect dstrc, Rect srcrc, uint color, int options, Rect* clip)
    {
        GLCacheItem* item = objectID in _map;
        if (item)
        {
            auto page = (cast(GLImageCachePage)item.page);
            page.drawItem(*item, dstrc, srcrc, color, options, clip);
        }
    }
}

private class GLGlyphCache : GLCache
{
    static class GLGlyphCachePage : GLCachePage
    {
        this(GLGlyphCache cache, int dx, int dy)
        {
            super(cache, dx, dy);
            Log.v("created glyph cache page ", dx, "x", dy);
        }

        GLCacheItem addItem(Glyph* glyph)
        {
            GLCacheItem cacheItem = reserveSpace(glyph.id, glyph.correctedBlackBoxX, glyph.blackBoxY);
            if (cacheItem is null)
                return null;
            //_drawbuf.drawGlyph(cacheItem._rc.left, cacheItem._rc.top, glyph, 0xFFFFFF);
            _drawbuf.drawGlyphToTexture(cacheItem._rc.left, cacheItem._rc.top, glyph);
            _needUpdateTexture = true;
            return cacheItem;
        }

        void drawItem(GLCacheItem item, Rect dstrc, Rect srcrc, uint color, Rect* clip)
        {
            if (_needUpdateTexture)
                updateTexture();
            if (_texture && _texture.ID != 0)
            {
                // convert coordinates to cached texture
                srcrc.offset(item._rc.left, item._rc.top);
                if (clip)
                {
                    int srcw = srcrc.width();
                    int srch = srcrc.height();
                    int dstw = dstrc.width();
                    int dsth = dstrc.height();
                    if (dstw)
                    {
                        srcrc.left += clip.left * srcw / dstw;
                        srcrc.right -= clip.right * srcw / dstw;
                    }
                    if (dsth)
                    {
                        srcrc.top += clip.top * srch / dsth;
                        srcrc.bottom -= clip.bottom * srch / dsth;
                    }
                    dstrc.left += clip.left;
                    dstrc.right -= clip.right;
                    dstrc.top += clip.top;
                    dstrc.bottom -= clip.bottom;
                }
                if (!dstrc.empty)
                {
                    //Log.d("drawing glyph with color ", color);
                    glSupport.queue.addTexturedRect(_texture, _tdx, _tdy, color, color, color,
                            color, srcrc, dstrc, false);
                }
            }
        }
    }

    /// Put new item to cache
    void put(Glyph* glyph)
    {
        updateTextureSize();
        GLCacheItem res = null;
        if (_activePage is null)
        {
            _activePage = new GLGlyphCachePage(this, tdx, tdy);
            _pages ~= _activePage;
        }
        res = (cast(GLGlyphCachePage)_activePage).addItem(glyph);
        if (!res)
        {
            auto page = new GLGlyphCachePage(this, tdx, tdy);
            _pages ~= page;
            res = page.addItem(glyph);
            _activePage = page;
        }
        _map[glyph.id] = res;
    }
    /// Draw cached item
    void drawItem(uint objectID, Rect dstrc, Rect srcrc, uint color, Rect* clip)
    {
        GLCacheItem* item = objectID in _map;
        if (item)
            (cast(GLGlyphCachePage)item.page).drawItem(*item, dstrc, srcrc, color, clip);
    }
}
