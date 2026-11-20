#define _POSIX_C_SOURCE 200809L

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>
#include <X11/XKBlib.h>

#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_CLIPBOARD 65536
#define MAX_KEYCODES 256

static Display *display = NULL;
static Window clipboard_window = None;
static Atom clipboard_atom = None;
static Atom utf8_atom = None;
static Atom targets_atom = None;
static Atom text_atom = None;
static Atom clipboard_property = None;
static int owns_clipboard = 0;
static unsigned char clipboard_text[MAX_CLIPBOARD];
static int clipboard_length = 0;
static char physical_key_names[MAX_KEYCODES][4];

static void read_keyboard_map(Display *d)
{
    XkbDescPtr keyboard;
    int first;
    int last;
    int code;

    memset(physical_key_names, 0, sizeof(physical_key_names));
    keyboard = XkbGetKeyboard(d, XkbGBN_AllComponentsMask, XkbUseCoreKbd);
    if (keyboard == NULL) {
        return;
    }

    if (keyboard->names != NULL && keyboard->names->keys != NULL) {
        first = keyboard->min_key_code;
        last = keyboard->max_key_code;

        if (first < 0) {
            first = 0;
        }
        if (last >= MAX_KEYCODES) {
            last = MAX_KEYCODES - 1;
        }

        for (code = first; code <= last; code++) {
            memcpy(physical_key_names[code], keyboard->names->keys[code].name, 4);
        }
    }

    XkbFreeKeyboard(keyboard, XkbAllComponentsMask, True);
}

/* Return the four-character XKB name, or 0 if the key is unknown. */
int portal_x11_key_name(unsigned int keycode, char *name)
{
    int i;

    if (name == NULL || keycode >= MAX_KEYCODES) {
        return 0;
    }
    if (physical_key_names[keycode][0] == '\0') {
        return 0;
    }
    for (i = 0; i < 4; i++) {
        if (physical_key_names[keycode][i] == '\0') {
            name[i] = ' ';
        } else {
            name[i] = physical_key_names[keycode][i];
        }
    }
    return 1;
}

void portal_x11_refresh_keyboard(Display *d)
{
    read_keyboard_map(d);
}

/* X11 clipboard data is transferred using selection request events. */
static void answer_clipboard_request(XSelectionRequestEvent *request)
{
    XSelectionEvent reply;
    Atom property;
    Atom supported[4];
    int ascii_only;
    int i;

    memset(&reply, 0, sizeof(reply));
    reply.type = SelectionNotify;
    reply.display = request->display;
    reply.requestor = request->requestor;
    reply.selection = request->selection;
    reply.target = request->target;
    reply.time = request->time;
    reply.property = None;

    property = request->property;
    if (property == None) {
        property = request->target;
    }

    if (owns_clipboard && request->selection == clipboard_atom) {
        if (request->target == targets_atom) {
            supported[0] = targets_atom;
            supported[1] = utf8_atom;
            supported[2] = XA_STRING;
            supported[3] = text_atom;

            XChangeProperty(display, request->requestor, property,
                            XA_ATOM, 32, PropModeReplace,
                            (unsigned char *)supported, 4);
            reply.property = property;
        } else if (request->target == utf8_atom ||
                   request->target == text_atom ||
                   request->target == XA_STRING) {
            ascii_only = 1;
            for (i = 0; i < clipboard_length; i++) {
                if (clipboard_text[i] >= 128) {
                    ascii_only = 0;
                    break;
                }
            }

            /* XA_STRING is only used for plain ASCII text here. */
            if (request->target != XA_STRING || ascii_only) {
                Atom data_type = utf8_atom;
                if (request->target == XA_STRING) {
                    data_type = XA_STRING;
                }
                XChangeProperty(display, request->requestor, property,
                                data_type, 8, PropModeReplace,
                                clipboard_text, clipboard_length);
                reply.property = property;
            }
        }
    }

    XSendEvent(display, request->requestor, False, 0, (XEvent *)&reply);
    XFlush(display);
}

int portal_x11_clipboard_event(XEvent *event)
{
    if (event->type == SelectionRequest) {
        if (event->xselectionrequest.owner == clipboard_window) {
            answer_clipboard_request(&event->xselectionrequest);
            return 1;
        }
    }

    if (event->type == SelectionClear) {
        if (event->xselectionclear.window == clipboard_window) {
            owns_clipboard = 0;
            return 1;
        }
    }

    if (event->type == SelectionNotify) {
        if (event->xselection.requestor == clipboard_window) {
            return 1;
        }
    }

    return 0;
}

void portal_x11_clipboard_set(const unsigned char *text, int length)
{
    if (display == NULL || clipboard_window == None || length < 0) {
        return;
    }
    if (length > 0 && text == NULL) {
        return;
    }
    if (length > MAX_CLIPBOARD) {
        length = MAX_CLIPBOARD;
    }

    if (length > 0) {
        memcpy(clipboard_text, text, (size_t)length);
    }
    clipboard_length = length;

    XSetSelectionOwner(display, clipboard_atom, clipboard_window, CurrentTime);
    XFlush(display);
    owns_clipboard =
        (XGetSelectionOwner(display, clipboard_atom) == clipboard_window);
}

int portal_x11_clipboard_get(unsigned char *output, int capacity)
{
    Window owner;
    XEvent event;
    int attempt;
    int status;
    int format;
    int count_to_copy;
    Atom data_type;
    unsigned long item_count;
    unsigned long bytes_left;
    unsigned char *received_text;
    struct timespec short_pause;

    if (display == NULL || output == NULL || capacity <= 0) {
        return 0;
    }
    if (capacity > MAX_CLIPBOARD) {
        capacity = MAX_CLIPBOARD;
    }

    owner = XGetSelectionOwner(display, clipboard_atom);

    if (owner == clipboard_window && owns_clipboard) {
        count_to_copy = clipboard_length;
        if (count_to_copy > capacity) {
            count_to_copy = capacity;
        }
        if (count_to_copy > 0) {
            memcpy(output, clipboard_text, (size_t)count_to_copy);
        }
        return count_to_copy;
    }
    if (owner == None) {
        return 0;
    }

    XDeleteProperty(display, clipboard_window, clipboard_property);
    XConvertSelection(display, clipboard_atom, utf8_atom,
                      clipboard_property, clipboard_window, CurrentTime);
    XFlush(display);

    short_pause.tv_sec = 0;
    short_pause.tv_nsec = 5000000L;

    /* Wait up to roughly 650 ms for another application to reply. */
    for (attempt = 0; attempt < 130; attempt++) {
        if (XCheckTypedWindowEvent(display, clipboard_window,
                                   SelectionRequest, &event)) {
            portal_x11_clipboard_event(&event);
        }

        if (XCheckTypedWindowEvent(display, clipboard_window,
                                   SelectionNotify, &event)) {
            if (event.xselection.selection != clipboard_atom) {
                continue;
            }
            if (event.xselection.property == None) {
                return 0;
            }

            received_text = NULL;
            data_type = None;
            format = 0;
            item_count = 0;
            bytes_left = 0;
            status = XGetWindowProperty(display, clipboard_window,
                                        clipboard_property, 0,
                                        (long)((capacity + 3) / 4), True,
                                        AnyPropertyType, &data_type, &format,
                                        &item_count, &bytes_left, &received_text);

            count_to_copy = 0;
            if (status == Success && format == 8 &&
                data_type == utf8_atom && received_text != NULL) {
                count_to_copy = (int)item_count;
                if (count_to_copy > capacity) {
                    count_to_copy = capacity;
                }
                memcpy(output, received_text, (size_t)count_to_copy);
            }

            if (received_text != NULL) {
                XFree(received_text);
            }
            return count_to_copy;
        }

        nanosleep(&short_pause, NULL);
    }

    return 0;
}

/* XImage stores pixels in the color layout required by the X11 visual. */
static XImage *create_image(Display *d, Visual *visual, int depth,
                            int width, int height)
{
    XImage *image;
    size_t bytes;

    image = XCreateImage(d, visual, (unsigned int)depth, ZPixmap, 0, NULL,
                         (unsigned int)width, (unsigned int)height, 32, 0);
    if (image == NULL) {
        return NULL;
    }

    if (image->bits_per_pixel != 16 && image->bits_per_pixel != 24 &&
        image->bits_per_pixel != 32) {
        XDestroyImage(image);
        return NULL;
    }

    bytes = (size_t)image->bytes_per_line * (size_t)height;
    image->data = (char *)calloc(bytes, 1);
    if (image->data == NULL) {
        XDestroyImage(image);
        return NULL;
    }

    return image;
}

/* Color masks tell us where the red, green, and blue bits belong. */
static unsigned long color_part(unsigned char value, unsigned long mask)
{
    int shift = 0;
    unsigned long range;
    unsigned long scaled;

    if (mask == 0) {
        return 0;
    }

    while ((mask & 1UL) == 0) {
        mask = mask >> 1;
        shift++;
    }

    range = mask;
    scaled = ((unsigned long)value * range + 127UL) / 255UL;
    return scaled << shift;
}

static void copy_pixels(XImage *image, const unsigned char *rgba,
                        int width, int height)
{
    int x;
    int y;
    size_t offset;
    unsigned long red;
    unsigned long green;
    unsigned long blue;

    for (y = 0; y < height; y++) {
        for (x = 0; x < width; x++) {
            offset = ((size_t)y * (size_t)width + (size_t)x) * 4;
            red = color_part(rgba[offset], image->red_mask);
            green = color_part(rgba[offset + 1], image->green_mask);
            blue = color_part(rgba[offset + 2], image->blue_mask);
            XPutPixel(image, x, y, red | green | blue);
        }
    }
}

int portal_x11_present(Display *d, Window window, GC gc, Visual *visual,
                       int depth, const unsigned char *rgba,
                       int width, int height, XImage **image)
{
    if (d == NULL || rgba == NULL || image == NULL ||
        width <= 0 || height <= 0) {
        return 0;
    }

    if (*image == NULL) {
        *image = create_image(d, visual, depth, width, height);
        if (*image == NULL) {
            return 0;
        }
    }

    copy_pixels(*image, rgba, width, height);
    XPutImage(d, window, gc, *image, 0, 0, 0, 0,
              (unsigned int)width, (unsigned int)height);
    XFlush(d);
    return 1;
}

void portal_x11_free_image(XImage *image)
{
    if (image != NULL) {
        XDestroyImage(image);
    }
}

void portal_x11_initialize(Display *d, Window owner, Atom clipboard,
                           Atom utf8, Atom targets, Atom text,
                           Atom property)
{
    display = d;
    clipboard_window = owner;
    clipboard_atom = clipboard;
    utf8_atom = utf8;
    targets_atom = targets;
    text_atom = text;
    clipboard_property = property;
    owns_clipboard = 0;
    clipboard_length = 0;
    read_keyboard_map(d);
}

void portal_x11_finalize(void)
{
    display = NULL;
    clipboard_window = None;
    clipboard_atom = None;
    utf8_atom = None;
    targets_atom = None;
    text_atom = None;
    clipboard_property = None;
    owns_clipboard = 0;
    clipboard_length = 0;
}
