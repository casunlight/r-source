/*
 *  R : A Computer Language for Statistical Data Analysis
 *  Copyright (C) 2007  The R Foundation
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, a copy is available at
 *  http://www.r-project.org/Licenses/
 *
 *  Cocoa Quartz device module
 *
 *  This file should be compiled only if AQUA is enabled
 */

#include "qdCocoa.h"

#include <sys/types.h>
#include <sys/time.h>
#include <unistd.h>

#include <R.h>
#include <Rinternals.h>
#include <R_ext/QuartzDevice.h>
#include <R_ext/eventloop.h>

/* --- userInfo structure for the CocoaDevice --- */
#define histsize 16

struct sQuartzCocoaDevice {
    QuartzDesc_t    qd;
    QuartzCocoaView *view;
    CGLayerRef      layer;   /* layer */
    CGContextRef    layerContext; /* layer context */
    CGContextRef    context; /* window drawing context */
    NSRect          bounds;  /* set along with context */
    BOOL            closing;
    int             inLocator;
    double          locator[2]; /* locaton click position (x,y) */
    BOOL            inHistoryRecall;
    int             inHistory;
    SEXP            history[histsize];
    int             histptr;
    const char *title;
};

static QuartzFunctions_t *qf;

/* --- QuartzCocoa view class --- */

@implementation QuartzCocoaView

+ (QuartzCocoaView*) quartzWindowWithRect: (NSRect) rect andInfo: (void*) info
{
    QuartzCocoaView* view = [[QuartzCocoaView alloc] initWithFrame: rect andInfo: info];
    NSWindow* window = [[NSWindow alloc] initWithContentRect: rect
                                                   styleMask: NSTitledWindowMask|NSClosableWindowMask|
        NSMiniaturizableWindowMask|NSResizableWindowMask//|NSTexturedBackgroundWindowMask
                                                     backing:NSBackingStoreBuffered defer:NO];
    [window setBackgroundColor:[NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:0.5]];
    [window setOpaque:NO];

    [window autorelease];
    [window setDelegate: view];
    [window setContentView: view];
    [window setInitialFirstResponder: view];
    /* [window setAcceptsMouseMovedEvents:YES]; not neeed now, maybe later */
    [window setTitle: [NSString stringWithUTF8String: ((QuartzCocoaDevice*)info)->title]];

    {
        NSMenu *menu;
        NSMenuItem *menuItem;
        BOOL soleMenu = (![NSApp mainMenu]); /* soleMenu is set if we have no menu at all, so we have to create it. Otherwise we are loading into an application that has already some menu, so we need only our specific stuff. */
        
        if (soleMenu) [NSApp setMainMenu:[[NSMenu alloc] init]];

        if ([[NSApp mainMenu] indexOfItemWithTitle:@"Quartz"]<0) {
            unichar leftArrow = NSLeftArrowFunctionKey, rightArrow = NSRightArrowFunctionKey;
            menu = [[NSMenu alloc] initWithTitle:@"Quartz"];
            menuItem = [[NSMenuItem alloc] initWithTitle:@"Back" action:@selector(historyBack:) keyEquivalent:[NSString stringWithCharacters:&leftArrow length:1]]; [menu addItem:menuItem]; [menuItem release];
            menuItem = [[NSMenuItem alloc] initWithTitle:@"Forward" action:@selector(historyForward:) keyEquivalent:[NSString stringWithCharacters:&rightArrow length:1]]; [menu addItem:menuItem]; [menuItem release];
            menuItem = [[NSMenuItem alloc] initWithTitle:@"Clear History" action:@selector(historyFlush:) keyEquivalent:@"L"]; [menu addItem:menuItem]; [menuItem release];
            menuItem = [[NSMenuItem alloc] initWithTitle:@"History" action:nil keyEquivalent:@""];
            [menuItem setSubmenu:menu];
            if (soleMenu)
                [[NSApp mainMenu] addItem:menuItem];
            else {
                int wmi; /* put us just before the Windows menu if possible */
                if ([NSApp windowsMenu] && ((wmi = [[NSApp mainMenu] indexOfItemWithSubmenu: [NSApp windowsMenu]])>=0))
                    [[NSApp mainMenu] insertItem: menuItem atIndex: wmi];
                else
                    [[NSApp mainMenu] addItem:menuItem];
            }
        }
        if (soleMenu) { /* those should be standard if we have some menu */
            menu = [[NSMenu alloc] initWithTitle:@"Window"];
            
            menuItem = [[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"]; [menu addItem:menuItem];
            menuItem = [[NSMenuItem alloc] initWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""]; [menu addItem:menuItem];
            
            /* Add to menubar */
            menuItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
            [menuItem setSubmenu:menu];
            [[NSApp mainMenu] addItem:menuItem];
            [NSApp setWindowsMenu:menu];
            [menu release];
            [menuItem release];
        }        
    }
    
    return view;
}

- (id) initWithFrame: (NSRect) frame andInfo: (void*) info
{
    self = [super initWithFrame: frame];
    if (self) {
        ci = (QuartzCocoaDevice*) info;
        ci->view = self;
        ci->closing = NO;
        ci->inLocator = NO;
        ci->inHistoryRecall = NO;
        ci->inHistory = -1;
        ci->histptr = 0;
        memset(ci->history, 0, sizeof(ci->history));
    }
    return self;
}

- (BOOL)isFlipped { return YES; } /* R uses flipped coordinates */

- (void)drawRect:(NSRect)aRect
{
    CGRect rect;
    CGContextRef ctx = [[NSGraphicsContext currentContext] graphicsPort];
    ci->context = ctx;
    ci->bounds = [self bounds];        
    rect = CGRectMake(0.0, 0.0, ci->bounds.size.width, ci->bounds.size.height);
    /* Rprintf("drawRect, ctx=%p, bounds=(%f x %f)\n", ctx, ci->bounds.size.width, ci->bounds.size.height); */
    if (!ci->layer) {
        CGSize size = CGSizeMake(ci->bounds.size.width, ci->bounds.size.height);
        /* Rprintf(" - have no layer, creating one (%f x %f)\n", ci->bounds.size.width, ci->bounds.size.height); */
        ci->layer = CGLayerCreateWithContext(ctx, size, 0);
        ci->layerContext = CGLayerGetContext(ci->layer);
        qf->ResetContext(ci->qd);
        if (ci->inHistoryRecall && ci->inHistory >= 0) {
            qf->RestoreSnapshot(ci->qd, ci->history[ci->inHistory]);
            ci->inHistoryRecall = NO;
        } else
            qf->ReplayDisplayList(ci->qd);
    } else {
        CGSize size = CGLayerGetSize(ci->layer);
        /* Rprintf(" - have layer %p\n", ci->layer); */
        if (size.width != rect.size.width || size.height != rect.size.height) { /* resize */
            /* Rprintf(" - but wrong size (%f x %f vs %f x %f; drawing scaled version\n", size.width, size.height, rect.size.width, rect.size.height); */
            
            /* if we are in live resize, skip this all */
            if (![self inLiveResize]) {
                /* first draw a rescaled version */
                CGContextDrawLayerInRect(ctx, rect, ci->layer);
                /* release old layer */
                CGLayerRelease(ci->layer);
                ci->layer = 0;
                ci->layerContext = 0;
                /* set size */
                qf->SetScaledSize(ci->qd, ci->bounds.size.width, ci->bounds.size.height);
                /* issue replay */
                if (ci->inHistoryRecall && ci->inHistory >= 0) {
                    qf->RestoreSnapshot(ci->qd, ci->history[ci->inHistory]);
                    ci->inHistoryRecall = NO;
                } else
                    qf->ReplayDisplayList(ci->qd);
            }
        }
    }
    if ([self inLiveResize]) CGContextSetAlpha(ctx, 0.6); 
    if (ci->layer)
        CGContextDrawLayerInRect(ctx, rect, ci->layer);
    if ([self inLiveResize]) CGContextSetAlpha(ctx, 1.0); 
}

- (void)mouseDown:(NSEvent *)theEvent
{
    if (ci->inLocator) {
        NSPoint pt = [theEvent locationInWindow];
        unsigned int mf = [theEvent modifierFlags];
        ci->locator[0] = pt.x;
        ci->locator[1] = pt.y;
        if (mf&NSControlKeyMask)
            ci->locator[0] = -1.0;
        ci->inLocator = NO;
    }
}

static void QuartzCocoa_SaveHistory(QuartzCocoaDevice *ci, int last) {
    SEXP ss = (SEXP) qf->GetSnapshot(ci->qd, last);
    if (ss) { /* ss will be NULL if there is no content, e.g. during the first call */
        R_PreserveObject(ss);
        if (ci->inHistory != -1) { /* if we are editing an existing snapshot, replace it */
            /* Rprintf("(updating plot in history at %d)\n", ci->inHistory); */
            if (ci->history[ci->inHistory]) R_ReleaseObject(ci->history[ci->inHistory]);
            ci->history[ci->inHistory] = ss;
        } else {
            /* Rprintf("(adding plot to history at %d)\n", ci->histptr); */
            if (ci->history[ci->histptr]) R_ReleaseObject(ci->history[ci->histptr]);
            ci->history[ci->histptr++] = ss;
            ci->histptr &= histsize - 1;
        }
    }
}

- (void)historyBack: (id) sender
{
    int hp = ci->inHistory - 1;
    if (ci->inHistory == -1)
        hp = (ci->histptr - 1);
    hp &= histsize - 1;
    if (hp == ci->histptr || !ci->history[hp])
        return;	
    if (qf->GetDirty(ci->qd)) /* save the current snapshot if it is dirty */
        QuartzCocoa_SaveHistory(ci, 0);
    ci->inHistory = hp;
    ci->inHistoryRecall = YES;
    /* Rprintf("(activating history entry %d) ", hp); */
    /* get rid of the current layer and force a repaint which will fetch the right entry */
    CGLayerRelease(ci->layer);
    ci->layer = 0;
    ci->layerContext = 0;
    [self setNeedsDisplay:YES];
}

- (void)historyForward: (id) sender
{
    int hp = ci->inHistory + 1;
    if (ci->inHistory == -1) return;
    hp &= histsize - 1;
    if (hp == ci->histptr || !ci->history[hp]) /* we can't really get past the last entry */
        return;
    if (qf->GetDirty(ci->qd)) /* save the current snapshot if it is dirty */
        QuartzCocoa_SaveHistory(ci, 0);
    
    ci->inHistory = hp;
    /* Rprintf("(activating history entry %d)\n", hp); */
    ci->inHistoryRecall = YES;
    
    CGLayerRelease(ci->layer);
    ci->layer = 0;
    ci->layerContext = 0;
    [self setNeedsDisplay:YES];
}	

- (void)historyFlush: (id) sender
{
    int i = 0;
    ci->inHistory = -1;
    ci->inHistoryRecall = NO;
    ci->histptr = 0;
    while (i < histsize) {
        if (ci->history[i]) {
            R_ReleaseObject(ci->history[i]);
            ci->history[i]=0;
        }
        i++;
    }
}

- (void)keyDown:(NSEvent *)theEvent
{
    /* Rprintf("keyCode=%d\n", [theEvent keyCode]); */
}

- (void)viewDidEndLiveResize
{
    [self setNeedsDisplay: YES];
}

- (void)windowWillClose:(NSNotification *)aNotification {
    ci->closing = YES;
    qf->Kill(ci->qd);
}

- (void)resetCursorRects
{
    if (ci->inLocator)
        [self addCursorRect:[self bounds] cursor:[NSCursor crosshairCursor]];
}

@end

/* --- Cocoa event loop
   This EL is enabled upon the first use of Quartz or alternatively using
   the QuartzCocoa_SetupEventLoop function */

static BOOL el_active = YES;   /* the slave thread work until this is NO */
static BOOL el_fired  = NO;    /* flag set when an event was fired */
static int  el_ofd, el_ifd;    /* communication file descriptors */
static unsigned long el_sleep; /* latency in ms */
static long el_serial = 0;     /* serial number for the time slice */
static long el_pe_serial = 0;  /* ProcessEvents serial number, event are
                                  only when the serial number changes */

/* helper function - sleep X milliseconds */
static void millisleep(unsigned long tout) {
    struct timeval tv;
    tv.tv_usec = (tout%1000)*1000;
    tv.tv_sec  = tout/1000;
    select(0, 0, 0, 0, &tv);
}

/* from aqua.c */
extern void (*ptr_R_ProcessEvents)(void);

static void cocoa_process_events() {
    /* this is a precaution if cocoa_process_events is called
       via R_ProcessEvents and the R code calls it too often */
    if (el_serial != el_pe_serial) {
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSAnyEventMask
                                          untilDate:nil
                                             inMode:NSDefaultRunLoopMode 
                                            dequeue:YES]))
            [NSApp sendEvent:event];
        el_pe_serial = el_serial;
    }
}

static void input_handler(void *data) {
    char buf[16];
    
    read(el_ifd, buf, 16);
    cocoa_process_events();
    el_fired = NO;
}

@interface ELThread : NSObject
- (int) eventsThread: (id) args;
@end

@implementation ELThread
- (int) eventsThread: (id) arg
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    char buf[16];
    
    while (el_active) {
        millisleep(el_sleep);
        el_serial++;
        if (!el_fired) {
            el_fired = YES; *buf=0;
            write(el_ofd, buf, 1);
        }
    }
    
    [pool release];
    return 0;
}
@end

static ELThread* el_obj = nil;

/* setup Cocoa event loop */
void QuartzCocoa_SetupEventLoop(int flags, unsigned long latency) {
    if (!el_obj) {
        int fds[2];
        pipe(fds);
        el_ifd = fds[0];
        el_ofd = fds[1];

        if (flags&QCF_SET_PEPTR)
            ptr_R_ProcessEvents = cocoa_process_events;

        el_sleep = latency;
        
        addInputHandler(R_InputHandlers, el_ifd, &input_handler, 31);

        el_obj = [[ELThread alloc] init];
        [NSThread detachNewThreadSelector:@selector(eventsThread:) toTarget:el_obj withObject:nil];
    }
    if (flags&QCF_SET_FRONT) {
        void CPSEnableForegroundOperation(ProcessSerialNumber* psn);
        ProcessSerialNumber myProc, frProc;
        Boolean sameProc;
        
        if (GetFrontProcess(&frProc) == noErr) {
            if (GetCurrentProcess(&myProc) == noErr) {
                if (SameProcess(&frProc, &myProc, &sameProc) == noErr && !sameProc) {
                    CPSEnableForegroundOperation(&myProc);
                }
                SetFrontProcess(&myProc);
            }
        }
    }
    
}

/* set Cocoa event loop latency in ms */
int QuartzCocoa_SetLatency(unsigned long latency) {
    el_sleep = latency;
    return (el_obj)?YES:NO;
}

/*----- R Quartz interface ------*/

static int cocoa_initialized = 0;
static NSAutoreleasePool *global_pool = 0;

static void initialize_cocoa() {  
    NSApplicationLoad();
    global_pool = [[NSAutoreleasePool alloc] init];

    if (!ptr_R_ProcessEvents)
        QuartzCocoa_SetupEventLoop(QCF_SET_PEPTR|QCF_SET_FRONT, 100);
    
    [NSApplication sharedApplication];
    cocoa_process_events();
}

static CGContextRef QuartzCocoa_GetCGContext(QuartzDesc_t dev, void *userInfo) {
    return ((QuartzCocoaDevice*)userInfo)->layerContext;
}

static void QuartzCocoa_Close(QuartzDesc_t dev,void *userInfo) {
    QuartzCocoaDevice *ci = (QuartzCocoaDevice*)userInfo;
	
    /* cancel any locator events */
    ci->inLocator = NO;
    ci->locator[0] = -1.0;
	
    /* release all history objects */
    ci->inHistory = -1;
    ci->inHistoryRecall = NO;
    ci->histptr = 0;
    {
        int i = 0;
        while (i < histsize) {
            if (ci->history[i]) {
                R_ReleaseObject(ci->history[i]);
                ci->history[i] = 0;
            }
            i++;
        }
    }
	
    /* close the window (if it's not already closing) */
    if (ci && ci->view && !ci->closing)
        [[ci->view window] close];
}

static int QuartzCocoa_Locator(QuartzDesc_t dev, void* userInfo, double *x, double*y) {
    QuartzCocoaDevice *ci = (QuartzCocoaDevice*)userInfo;
    
    if (!ci || !ci->view || ci->inLocator) return FALSE;
    
    ci->locator[0] = -1.0;
    ci->inLocator = YES;
    [[ci->view window] invalidateCursorRectsForView: ci->view];
    
    while (ci->inLocator) {
        NSEvent *event = [NSApp nextEventMatchingMask:NSAnyEventMask
                                            untilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]
                                               inMode:NSDefaultRunLoopMode 
                                              dequeue:YES];
        if (event) [NSApp sendEvent:event];
    }
    [[ci->view window] invalidateCursorRectsForView: ci->view];
    *x = ci->locator[0];
    *y = ci->locator[1];
    return (*x >= 0.0)?TRUE:FALSE;
}

static void QuartzCocoa_NewPage(QuartzDesc_t dev,void *userInfo, int flags) {
    QuartzCocoaDevice *ci = (QuartzCocoaDevice*)userInfo;
    if (!ci) return;
    if ((flags&QNPF_REDRAW)==0) { /* no redraw -> really new page */
        QuartzCocoa_SaveHistory(ci, 1);
        ci->inHistory = -1;
    }
    if (ci->layer) {
        CGLayerRelease(ci->layer);
        ci->layer = 0;
        ci->layerContext = 0;
    }
    if (ci->context) {
        CGSize size = CGSizeMake(ci->bounds.size.width, ci->bounds.size.height);
        ci->layer = CGLayerCreateWithContext(ci->context, size, 0);
        ci->layerContext = CGLayerGetContext(ci->layer);
        qf->ResetContext(dev);
        /* Rprintf(" - creating new layer (%p - ctx: %p, %f x %f)\n", ci->layer, ci->layerContext,  size.width, size.height); */
    }
}

static void QuartzCocoa_Sync(QuartzDesc_t dev,void *userInfo) {
    QuartzCocoaDevice *ci = (QuartzCocoaDevice*)userInfo;
    if (!ci || !ci->view) return;
    [ci->view setNeedsDisplay: YES];
}

static void QuartzCocoa_State(QuartzDesc_t dev, void *userInfo, int state) {
    QuartzCocoaDevice *ci = (QuartzCocoaDevice*)userInfo;
    NSString *title;
    if (!ci || !ci->view) return;
    if (!ci->title) ci->title=strdup("Quartz %d");
    title = [NSString stringWithFormat: [NSString stringWithUTF8String: ci->title], qf->DevNumber(dev)];
    if (state) title = [title stringByAppendingString: @" [*]"];
    [[ci->view window] setTitle: title];
}

Rboolean QuartzCocoa_DeviceCreate(void *dd, QuartzFunctions_t *fn, QuartzParameters_t *par)
{
    void *qd;
    double *dpi = par->dpi, width = par->width, height = par->height;
    double mydpi[2] = { 72.0, 72.0 };
    double scalex = 1.0, scaley = 1.0;
    QuartzCocoaDevice *dev;
	
    if (!qf) qf = fn;
    
    { /* check whether we have access to a display at all */
	CGDisplayCount dcount = 0;
	CGGetOnlineDisplayList(255, NULL, &dcount);
	if (dcount < 1) {
	    warning("No displays are available");
	    return FALSE;
	}
    }

    if (!dpi) {
        CGDirectDisplayID md = CGMainDisplayID();
        if (md) {
            CGSize ds = CGDisplayScreenSize(md);
            double width  = (double)CGDisplayPixelsWide(md);
            double height = (double)CGDisplayPixelsHigh(md);
            mydpi[0] = width / ds.width*25.4;
            mydpi[1] = height / ds.height*25.4;
            /* Rprintf("screen resolution %f x %f\n", mydpi[0], mydpi[1]); */
        }
        dpi = mydpi;
    }
    
    scalex = dpi[0] / 72.0;
    scaley = dpi[1] / 72.0;

    dev = malloc(sizeof(QuartzCocoaDevice));
    memset(dev, 0, sizeof(QuartzCocoaDevice));

    QuartzBackend_t qdef = {
	sizeof(qdef), width, height, scalex, scaley, par->pointsize,
	par->bg, par->canvas, par->flags | QDFLAG_INTERACTIVE | QDFLAG_DISPLAY_LIST,
	dev,
	QuartzCocoa_GetCGContext,
	QuartzCocoa_Locator,
	QuartzCocoa_Close,
	QuartzCocoa_NewPage,
	QuartzCocoa_State,
	NULL,/* par */
	QuartzCocoa_Sync,
    };
    
    qd = qf->Create(dd, &qdef);
    if (!qd) return FALSE;
    dev->qd = qd;
    /* we cannot substitute the device number as it is not yet known at this point */
    dev->title = strdup(par->title);
    {
        NSRect rect = NSMakeRect(20.0, 20.0, /* FIXME: proper position */
                                 qf->GetScaledWidth(qd), qf->GetScaledHeight(qd));
        if (!cocoa_initialized) initialize_cocoa();
        /* Rprintf("scale=%f/%f; size=%f x %f\n", scalex, scaley, rect.size.width, rect.size.height); */
        [QuartzCocoaView quartzWindowWithRect: rect andInfo: dev];
    }
    [[dev->view window] makeKeyAndOrderFront: dev->view];
    /* FIXME: at this point we should paint the canvas colour */
    return TRUE;
}
