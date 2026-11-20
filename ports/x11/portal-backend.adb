with Ada.Calendar;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Interfaces.C;         use Interfaces.C;
with Interfaces.C.Strings; use Interfaces.C.Strings;
with System;               use type System.Address;
with Portal.Xlib;          use Portal.Xlib;

package body Portal.Backend with SPARK_Mode => Off is

   Initialized : Boolean := False;
   Display     : Display_Ptr := Null_Display;
   Screen      : int;
   Visual      : Visual_Ptr;
   Depth       : int;
   Graphics    : GC;
   WM_Delete   : Atom;
   Start       : Ada.Calendar.Time;

   --  C is used only for XKB's native key data, XImage and selections.
   procedure Native_Initialize
     (D : Display_Ptr; Owner : Xlib.Window;
      Clipboard, UTF8, Targets, Text_Atom, Property_Atom : Atom)
     with Import, Convention => C, External_Name => "portal_x11_initialize";
   procedure Native_Finalize
     with Import, Convention => C, External_Name => "portal_x11_finalize";
   procedure Native_Free_Image (Image : XImage_Ptr)
     with Import, Convention => C, External_Name => "portal_x11_free_image";
   function Native_Key_Name (Code : unsigned; Name : System.Address) return int
     with Import, Convention => C, External_Name => "portal_x11_key_name";
   procedure Native_Refresh_Keyboard (D : Display_Ptr)
     with Import, Convention => C, External_Name => "portal_x11_refresh_keyboard";
   function Native_Clipboard_Event (E : System.Address) return int
     with Import, Convention => C, External_Name => "portal_x11_clipboard_event";
   procedure Native_Clipboard_Set (Data : System.Address; Count : int)
     with Import, Convention => C, External_Name => "portal_x11_clipboard_set";
   function Native_Clipboard_Get (Data : System.Address; Capacity : int)
      return int
     with Import, Convention => C, External_Name => "portal_x11_clipboard_get";
   function Native_Present
     (D : Display_Ptr; H : Xlib.Window; G : GC; V : Visual_Ptr;
      Bpp : int; Data : System.Address; W, Ht : int;
      Image : access XImage_Ptr) return int
     with Import, Convention => C, External_Name => "portal_x11_present";

   Clipboard_Window : Xlib.Window := 0;
   Cursor_Visible : Boolean := True;
   Hidden_Cursor  : Xlib.Cursor := 0;
   Focus_Window   : Window_Id := No_Window;

   type Window_Slot is record
      Open   : Boolean := False;
      Handle : Xlib.Window := 0;
      Image : aliased XImage_Ptr := System.Null_Address;
      Image_Width : Natural := 0;
      Image_Height : Natural := 0;
      Size     : Bedrock.Screen.Size;
      Active_Cursor : Xlib.Cursor := 0;
      Last_Pos : Point := (0, 0);
      Has_Last_Pos : Boolean := False;
   end record;
   Slots : array (Valid_Window_Id) of Window_Slot;

   Max_Queue : constant := 256;
   Queue     : array (1 .. Max_Queue) of Event;
   Q_Head, Q_Count : Natural := 0;

   Keys_Down : array (Key) of Boolean := [others => False];
   Mods      : Modifiers := No_Modifiers;
   Buttons   : Button_State := [others => False];
   Text_Enabled : array (Valid_Window_Id) of Boolean := [others => False];

   function Id_Of (H : Xlib.Window) return Window_Id;
   function Intern_Atom (Name : String) return Atom;
   procedure Release_Image (W : Valid_Window_Id);
   procedure Enqueue (E : Event);
   function Dequeue return Event;
   function To_Key (Sym : XID) return Key;
   function Physical_Key_Symbol (Code : unsigned; Fallback : XID) return XID;
   function Create_Cursor (Shape : Cursor_Shape) return Xlib.Cursor;
   function Create_Hidden_Cursor return Xlib.Cursor;
   function State_To_Mods (State : unsigned) return Modifiers;
   procedure Translate (Raw : aliased XEvent_Raw);
   procedure Pump;
   function Pixel_Delta (New_Pos, Old_Pos : Pixels) return Pixels;

   function Is_Initialized return Boolean is
   begin
      return Initialized;
   end Is_Initialized;

   function Is_Open (W : Window_Id) return Boolean is
   begin
      if W = No_Window then
         return False;
      end if;
      return Slots (W).Open;
   end Is_Open;

   function Id_Of (H : Xlib.Window) return Window_Id is
   begin
      for W in Valid_Window_Id loop
         if Slots (W).Open and then Slots (W).Handle = H then
            return W;
         end if;
      end loop;
      return No_Window;
   end Id_Of;

   function Intern_Atom (Name : String) return Atom is
      C_Name : chars_ptr := New_String (Name);
      Result : Atom;
   begin
      Result := XInternAtom (Display, C_Name, 0);
      Free (C_Name);
      return Result;
   end Intern_Atom;

   procedure Release_Image (W : Valid_Window_Id) is
   begin
      if Slots (W).Image /= System.Null_Address then
         Native_Free_Image (Slots (W).Image);
         Slots (W).Image := System.Null_Address;
      end if;
      Slots (W).Image_Width := 0;
      Slots (W).Image_Height := 0;
   end Release_Image;

   procedure Enqueue (E : Event) is
   begin
      if Q_Count < Max_Queue then
         Queue ((Q_Head + Q_Count) mod Max_Queue + 1) := E;
         Q_Count := Q_Count + 1;
      end if;
   end Enqueue;

   function Dequeue return Event is
      E : constant Event := Queue (Q_Head + 1);
   begin
      Q_Head := (Q_Head + 1) mod Max_Queue;
      Q_Count := Q_Count - 1;
      return E;
   end Dequeue;

   function Physical_Key_Symbol (Code : unsigned; Fallback : XID) return XID is
      Name : aliased String (1 .. 4) := (others => ' ');
      Found : int;

      type Key_Name_Entry is record
         Name   : String (1 .. 4);
         Symbol : XID;
      end record;

      type Key_Name_Table is array (Positive range <>) of Key_Name_Entry;
      Special_Keys : constant Key_Name_Table :=
        [("TLDE", 16#60#), ("BKSP", 16#FF08#), ("TAB ", 16#FF09#),
         ("CAPS", 16#FFE5#), ("RTRN", 16#FF0D#), ("SPCE", 16#20#),
         ("BKSL", 16#5C#), ("LFSH", 16#FFE1#), ("RTSH", 16#FFE2#),
         ("LCTL", 16#FFE3#), ("RCTL", 16#FFE4#),
         ("LALT", 16#FFE9#), ("RALT", 16#FFEA#),
         ("LWIN", 16#FFEB#), ("RWIN", 16#FFEC#),
         ("ESC ", 16#FF1B#),
         ("LEFT", 16#FF51#), ("RGHT", 16#FF53#),
         ("UP  ", 16#FF52#), ("DOWN", 16#FF54#),
         ("INS ", 16#FF63#), ("DELE", 16#FFFF#),
         ("HOME", 16#FF50#), ("END ", 16#FF57#),
         ("PGUP", 16#FF55#), ("PGDN", 16#FF56#),
         ("NMLK", 16#FF7F#), ("SCLK", 16#FF14#),
         ("PAUS", 16#FF13#), ("PRSC", 16#FF61#),
         ("MENU", 16#FF67#),
         ("AC10", 16#3B#), ("AC11", 16#27#),
         ("AD11", 16#5B#), ("AD12", 16#5D#),
         ("AB08", 16#2C#), ("AB09", 16#2E#),
         ("AB10", 16#2F#), ("AE11", 16#2D#),
         ("AE12", 16#3D#),
         ("KP0 ", 16#FFB0#), ("KP1 ", 16#FFB1#),
         ("KP2 ", 16#FFB2#), ("KP3 ", 16#FFB3#),
         ("KP4 ", 16#FFB4#), ("KP5 ", 16#FFB5#),
         ("KP6 ", 16#FFB6#), ("KP7 ", 16#FFB7#),
         ("KP8 ", 16#FFB8#), ("KP9 ", 16#FFB9#),
         ("KPDV", 16#FFAF#), ("KPMU", 16#FFAA#),
         ("KPSU", 16#FFAD#), ("KPAD", 16#FFAB#),
         ("KPEN", 16#FF8D#), ("KPDL", 16#FFAE#)];

      Number     : Natural;
      Upper_Row  : constant String := "QWERTYUIO";
      Middle_Row : constant String := "ASDFGHJKL";
      Lower_Row  : constant String := "ZXCVBNM";
   begin
      Found := Native_Key_Name (Code, Name'Address);
      if Found = 0 then
         return Fallback;
      end if;

      if Name = "AD10" then
         return XID (Character'Pos ('P'));
      elsif Name (1 .. 3) = "AD0" and then Name (4) in '1' .. '9' then
         Number := Character'Pos (Name (4)) - Character'Pos ('1') + 1;
         return XID (Character'Pos (Upper_Row (Number)));
      elsif Name (1 .. 3) = "AC0" and then Name (4) in '1' .. '9' then
         Number := Character'Pos (Name (4)) - Character'Pos ('1') + 1;
         return XID (Character'Pos (Middle_Row (Number)));
      elsif Name (1 .. 3) = "AB0" and then Name (4) in '1' .. '7' then
         Number := Character'Pos (Name (4)) - Character'Pos ('1') + 1;
         return XID (Character'Pos (Lower_Row (Number)));
      elsif Name = "AE10" then
         return XID (Character'Pos ('0'));
      elsif Name (1 .. 3) = "AE0" and then Name (4) in '1' .. '9' then
         return XID (Character'Pos (Name (4)));
      elsif Name (1 .. 2) = "FK" and then Name (3) in '0' .. '1'
        and then Name (4) in '0' .. '9'
      then
         Number := (Character'Pos (Name (3)) - Character'Pos ('0')) * 10;
         Number := Number + Character'Pos (Name (4)) - Character'Pos ('0');
         if Number in 1 .. 12 then
            return XID (16#FFBD# + Number);
         end if;
      end if;

      for Item of Special_Keys loop
         if Name = Item.Name then
            return Item.Symbol;
         end if;
      end loop;
      return Fallback;
   end Physical_Key_Symbol;

   function Create_Cursor (Shape : Cursor_Shape) return Xlib.Cursor is
      Cursor_Type : unsigned;
   begin
      case Shape is
         when I_Beam      => Cursor_Type := 152;
         when Crosshair   => Cursor_Type := 34;
         when Hand        => Cursor_Type := 60;
         when Resize_EW   => Cursor_Type := 108;
         when Resize_NS   => Cursor_Type := 116;
         when Resize_NWSE => Cursor_Type := 14;
         when Resize_NESW => Cursor_Type := 12;
         when Not_Allowed => Cursor_Type := 0;
         when Busy        => Cursor_Type := 150;
         when Arrow       => Cursor_Type := 68;
      end case;
      return XCreateFontCursor (Display, Cursor_Type);
   end Create_Cursor;

   function Create_Hidden_Cursor return Xlib.Cursor is
      Pixel_Data : aliased String (1 .. 1) := (1 => Character'Val (0));
      Black      : aliased XColor :=
        (Pixel => 0, Red => 0, Green => 0, Blue => 0,
         Flags => char'Val (0), Pad => char'Val (0));
      Image      : Xlib.Pixmap;
      Result     : Xlib.Cursor;
   begin
      if Hidden_Cursor /= 0 then
         return Hidden_Cursor;
      end if;

      Image := XCreateBitmapFromData
        (Display, XDefaultRootWindow (Display), Pixel_Data'Address, 1, 1);
      if Image = 0 then
         return 0;
      end if;
      Result := XCreatePixmapCursor
        (Display, Image, Image, Black'Access, Black'Access, 0, 0);
      if XFreePixmap (Display, Image) = 0 then
         null;
      end if;
      Hidden_Cursor := Result;
      return Hidden_Cursor;
   end Create_Hidden_Cursor;

   --  Match each X11 key symbol to a Portal key.
   function To_Key (Sym : XID) return Key is
   begin
      case Sym is
         when 16#41# | 16#61# => return Key_A;
         when 16#42# | 16#62# => return Key_B;
         when 16#43# | 16#63# => return Key_C;
         when 16#44# | 16#64# => return Key_D;
         when 16#45# | 16#65# => return Key_E;
         when 16#46# | 16#66# => return Key_F;
         when 16#47# | 16#67# => return Key_G;
         when 16#48# | 16#68# => return Key_H;
         when 16#49# | 16#69# => return Key_I;
         when 16#4A# | 16#6A# => return Key_J;
         when 16#4B# | 16#6B# => return Key_K;
         when 16#4C# | 16#6C# => return Key_L;
         when 16#4D# | 16#6D# => return Key_M;
         when 16#4E# | 16#6E# => return Key_N;
         when 16#4F# | 16#6F# => return Key_O;
         when 16#50# | 16#70# => return Key_P;
         when 16#51# | 16#71# => return Key_Q;
         when 16#52# | 16#72# => return Key_R;
         when 16#53# | 16#73# => return Key_S;
         when 16#54# | 16#74# => return Key_T;
         when 16#55# | 16#75# => return Key_U;
         when 16#56# | 16#76# => return Key_V;
         when 16#57# | 16#77# => return Key_W;
         when 16#58# | 16#78# => return Key_X;
         when 16#59# | 16#79# => return Key_Y;
         when 16#5A# | 16#7A# => return Key_Z;
         when 16#30# => return Key_0;
         when 16#31# => return Key_1;
         when 16#32# => return Key_2;
         when 16#33# => return Key_3;
         when 16#34# => return Key_4;
         when 16#35# => return Key_5;
         when 16#36# => return Key_6;
         when 16#37# => return Key_7;
         when 16#38# => return Key_8;
         when 16#39# => return Key_9;
         when 16#2D# => return Key_Minus;
         when 16#3D# => return Key_Equals;
         when 16#5B# => return Key_Left_Bracket;
         when 16#5D# => return Key_Right_Bracket;
         when 16#5C# => return Key_Backslash;
         when 16#3B# => return Key_Semicolon;
         when 16#27# => return Key_Apostrophe;
         when 16#60# => return Key_Grave;
         when 16#2C# => return Key_Comma;
         when 16#2E# => return Key_Period;
         when 16#2F# => return Key_Slash;
         when 16#FFB0# => return Key_KP_0;
         when 16#FFB1# => return Key_KP_1;
         when 16#FFB2# => return Key_KP_2;
         when 16#FFB3# => return Key_KP_3;
         when 16#FFB4# => return Key_KP_4;
         when 16#FFB5# => return Key_KP_5;
         when 16#FFB6# => return Key_KP_6;
         when 16#FFB7# => return Key_KP_7;
         when 16#FFB8# => return Key_KP_8;
         when 16#FFB9# => return Key_KP_9;
         when 16#FFAF# => return Key_KP_Divide;
         when 16#FFAA# => return Key_KP_Multiply;
         when 16#FFAD# => return Key_KP_Minus;
         when 16#FFAB# => return Key_KP_Plus;
         when 16#FF8D# => return Key_KP_Enter;
         when 16#FFAE# => return Key_KP_Period;
         when 16#FF61# => return Key_Print_Screen;
         when 16#FF14# => return Key_Scroll_Lock;
         when 16#FF13# => return Key_Pause;
         when 16#FF67# => return Key_Menu;
         when 16#FF0D# => return Key_Return;
         when 16#FF1B# => return Key_Escape;
         when 16#FF08# => return Key_Backspace;
         when 16#FF09# => return Key_Tab;
         when 16#20# => return Key_Space;
         when 16#FF63# => return Key_Insert;
         when 16#FFFF# => return Key_Delete;
         when 16#FF50# => return Key_Home;
         when 16#FF57# => return Key_End;
         when 16#FF55# => return Key_Page_Up;
         when 16#FF56# => return Key_Page_Down;
         when 16#FF51# => return Key_Left;
         when 16#FF53# => return Key_Right;
         when 16#FF52# => return Key_Up;
         when 16#FF54# => return Key_Down;
         when 16#FFBE# => return Key_F1;
         when 16#FFBF# => return Key_F2;
         when 16#FFC0# => return Key_F3;
         when 16#FFC1# => return Key_F4;
         when 16#FFC2# => return Key_F5;
         when 16#FFC3# => return Key_F6;
         when 16#FFC4# => return Key_F7;
         when 16#FFC5# => return Key_F8;
         when 16#FFC6# => return Key_F9;
         when 16#FFC7# => return Key_F10;
         when 16#FFC8# => return Key_F11;
         when 16#FFC9# => return Key_F12;
         when 16#FFE1# => return Key_Left_Shift;
         when 16#FFE2# => return Key_Right_Shift;
         when 16#FFE3# => return Key_Left_Ctrl;
         when 16#FFE4# => return Key_Right_Ctrl;
         when 16#FFE9# => return Key_Left_Alt;
         when 16#FFEA# => return Key_Right_Alt;
         when 16#FFEB# => return Key_Left_Super;
         when 16#FFEC# => return Key_Right_Super;
         when 16#FFE5# => return Key_Caps_Lock;
         when others => return Key_Unknown;
      end case;
   end To_Key;

   function State_To_Mods (State : unsigned) return Modifiers is
      Result : Modifiers := No_Modifiers;
   begin
      Result.Shift     := (State and 1) /= 0;
      Result.Caps_Lock := (State and 2) /= 0;
      Result.Ctrl      := (State and 4) /= 0;
      Result.Alt       := (State and 8) /= 0;
      Result.Super     := (State and 64) /= 0;
      return Result;
   end State_To_Mods;

   function Pixel_Delta (New_Pos, Old_Pos : Pixels) return Pixels is
      Difference : constant Integer := Integer (New_Pos) - Integer (Old_Pos);
   begin
      if Difference > Integer (Pixels'Last) then
         return Pixels'Last;
      elsif Difference < Integer (Pixels'First) then
         return Pixels'First;
      else
         return Pixels (Difference);
      end if;
   end Pixel_Delta;

   --  X11 returns different event records in the same memory buffer.
   --  These records let us read the fields for each type of event.
   procedure Translate (Raw : aliased XEvent_Raw) is
      Any : XAny_Event with Import, Address => Raw'Address;
      KE  : aliased XKey_Event with Import, Address => Raw'Address;
      BE  : XButton_Event with Import, Address => Raw'Address;
      CE  : XConfigure_Event with Import, Address => Raw'Address;
      CM  : XClient_Message_Event with Import, Address => Raw'Address;

      Keyboard_Map_Changed : constant := 34;
      W : constant Window_Id := Id_Of (Any.Win);
      T : constant Ticks := Now;
   begin
      if Any.Kind = Keyboard_Map_Changed then
         Native_Refresh_Keyboard (Display);
         return;
      end if;

      if W = No_Window then
         return;
      end if;

      case Any.Kind is
         when Key_Press | Key_Release =>
            declare
               Layout_Symbol : constant XID := XLookupKeysym (KE'Access, 0);
               Physical_Symbol : constant XID :=
                 Physical_Key_Symbol (KE.Keycode, Layout_Symbol);
               K : constant Key := To_Key (Physical_Symbol);
               Pressed : constant Boolean := Any.Kind = Key_Press;
               Repeated : constant Boolean := Pressed and then Keys_Down (K);
            begin
               Mods := State_To_Mods (KE.State);
               Keys_Down (K) := Pressed;

               if Pressed then
                  Enqueue ((Kind => Key_Down, Time => T, Window => W,
                            Key => K, Mods => Mods, Repeat => Repeated));
               else
                  Enqueue ((Kind => Key_Up, Time => T, Window => W,
                            Key => K, Mods => Mods, Repeat => Repeated));
               end if;

               --  Basic printable ASCII text input, not a complete IME.
               if Pressed and then Text_Enabled (W) then
                  if Layout_Symbol in 16#20# .. 16#7E# then
                     Enqueue ((Kind => Text_Input, Time => T, Window => W,
                               Text => [Character'Val (Layout_Symbol), ' ', ' ', ' '],
                               Length => 1));
                  end if;
               end if;
            end;

         when Button_Press | Button_Release =>
            declare
               P : constant Point := (Pixels (BE.X), Pixels (BE.Y));
               Pressed : constant Boolean := Any.Kind = Button_Press;
               B : Mouse_Button := Left;
               Known_Button : Boolean := True;
            begin
               --  X11 sends wheel motion as button presses.
               if BE.Button = 4 or else BE.Button = 5 then
                  if Pressed then
                     if BE.Button = 4 then
                        Enqueue ((Kind => Mouse_Wheel, Time => T, Window => W,
                                  Wheel_X => 0, Wheel_Y => 1, Wheel_At => P));
                     else
                        Enqueue ((Kind => Mouse_Wheel, Time => T, Window => W,
                                  Wheel_X => 0, Wheel_Y => -1, Wheel_At => P));
                     end if;
                  end if;
               elsif BE.Button = 6 or else BE.Button = 7 then
                  if Pressed then
                     if BE.Button = 6 then
                        Enqueue ((Kind => Mouse_Wheel, Time => T, Window => W,
                                  Wheel_X => -1, Wheel_Y => 0, Wheel_At => P));
                     else
                        Enqueue ((Kind => Mouse_Wheel, Time => T, Window => W,
                                  Wheel_X => 1, Wheel_Y => 0, Wheel_At => P));
                     end if;
                  end if;
               else
                  case BE.Button is
                     when 1 => B := Left;
                     when 2 => B := Middle;
                     when 3 => B := Right;
                     when 8 => B := Back;
                     when 9 => B := Forward;
                     when others => Known_Button := False;
                  end case;

                  if Known_Button then
                     Buttons (B) := Pressed;
                     if Pressed then
                        Enqueue ((Kind => Mouse_Down, Time => T, Window => W,
                                  Button => B, Where => P, Clicks => 1));
                     else
                        Enqueue ((Kind => Mouse_Up, Time => T, Window => W,
                                  Button => B, Where => P, Clicks => 1));
                     end if;
                  end if;
               end if;
            end;

         when Motion_Notify =>
            declare
               P : constant Point := (Pixels (BE.X), Pixels (BE.Y));
               DX : Pixels := 0;
               DY : Pixels := 0;
            begin
               if Slots (W).Has_Last_Pos then
                  DX := Pixel_Delta (P.X, Slots (W).Last_Pos.X);
                  DY := Pixel_Delta (P.Y, Slots (W).Last_Pos.Y);
               end if;

               Slots (W).Last_Pos := P;
               Slots (W).Has_Last_Pos := True;
               Enqueue ((Kind => Mouse_Move, Time => T, Window => W,
                         At_Pos => P, Delta_X => DX, Delta_Y => DY,
                         Held => Buttons));
            end;

         when Enter_Notify =>
            Enqueue ((Kind => Mouse_Enter, Time => T, Window => W));

         when Leave_Notify =>
            Enqueue ((Kind => Mouse_Leave, Time => T, Window => W));

         when Focus_In =>
            Focus_Window := W;
            Enqueue ((Kind => Window_Focus_In, Time => T, Window => W));

         when Focus_Out =>
            if Focus_Window = W then
               Focus_Window := No_Window;
            end if;
            Slots (W).Has_Last_Pos := False;
            Keys_Down := [others => False];
            Enqueue ((Kind => Window_Focus_Out, Time => T, Window => W));

         when Expose =>
            Enqueue ((Kind => Window_Expose, Time => T, Window => W));

         when Map_Notify =>
            Enqueue ((Kind => Window_Shown, Time => T, Window => W));

         when Unmap_Notify =>
            Enqueue ((Kind => Window_Hidden, Time => T, Window => W));

         when Configure_Notify =>
            declare
               New_Size : constant Bedrock.Screen.Size :=
                 (Extent (CE.Width), Extent (CE.Height));
            begin
               if New_Size /= Slots (W).Size then
                  Slots (W).Size := New_Size;
                  Enqueue ((Kind => Window_Resized, Time => T,
                            Window => W, Size => New_Size));
               end if;
            end;

         when Client_Message =>
            if Atom (CM.Data_L0) = WM_Delete then
               Enqueue ((Kind => Window_Close, Time => T, Window => W));
            end if;

         when others =>
            null;
      end case;
   end Translate;

   procedure Pump is
      Raw : aliased XEvent_Raw;
   begin
      while XPending (Display) > 0 loop
         XNextEvent (Display, Raw);
         if Native_Clipboard_Event (Raw'Address) = 0 then
            Translate (Raw);
         end if;
      end loop;
   end Pump;

   procedure Initialize (Success : out Boolean) is
      Supported : aliased Bool;
      Name : chars_ptr := New_String ("WM_DELETE_WINDOW");
   begin
      Start := Ada.Calendar.Clock;
      Display := XOpenDisplay (Null_Ptr);
      if Display = Null_Display then
         Success := False;
         Free (Name);
         return;
      end if;
      Screen   := XDefaultScreen (Display);
      Visual   := XDefaultVisual (Display, Screen);
      Depth    := XDefaultDepth (Display, Screen);
      Graphics := XDefaultGC (Display, Screen);
      WM_Delete := XInternAtom (Display, Name, 0);
      Free (Name);
      if XkbSetDetectableAutoRepeat (Display, 1, Supported'Access) = 0 then
         null;
      end if;
      Clipboard_Window := XCreateSimpleWindow
        (Display, XDefaultRootWindow (Display), 0, 0, 1, 1, 0, 0, 0);
      if Clipboard_Window = 0 then
         XCloseDisplay (Display);
         Display := Null_Display;
         Success := False;
         return;
      end if;
      Native_Initialize
        (Display, Clipboard_Window,
         Intern_Atom ("CLIPBOARD"), Intern_Atom ("UTF8_STRING"),
         Intern_Atom ("TARGETS"), Intern_Atom ("TEXT"),
         Intern_Atom ("PORTAL_CLIPBOARD"));
      Q_Head := 0;
      Q_Count := 0;
      Cursor_Visible := True;
      Hidden_Cursor := 0;
      Focus_Window := No_Window;
      Text_Enabled := [others => False];
      Keys_Down := [others => False];
      Buttons := [others => False];
      Mods := No_Modifiers;
      Initialized := True;
      Success := True;
   end Initialize;

   procedure Finalize is
   begin
      for W in Valid_Window_Id loop
         if Slots (W).Open then
            Release_Image (W);
            if Slots (W).Active_Cursor /= 0 then
               if XFreeCursor (Display, Slots (W).Active_Cursor) = 0 then
                  null;
               end if;
            end if;
            XDestroyWindow (Display, Slots (W).Handle);
            Slots (W).Open := False;
         end if;
      end loop;
      if Hidden_Cursor /= 0 then
         if XFreeCursor (Display, Hidden_Cursor) = 0 then
            null;
         end if;
         Hidden_Cursor := 0;
      end if;
      Native_Finalize;
      if Clipboard_Window /= 0 then
         XDestroyWindow (Display, Clipboard_Window);
         Clipboard_Window := 0;
      end if;
      XCloseDisplay (Display);
      Display := Null_Display;
      Initialized := False;
   end Finalize;

   procedure Create_Window
     (Title  : String;
      Size   : Bedrock.Screen.Size;
      Flags  : Window_Flags;
      Window : out Window_Id)
   is
      H    : Xlib.Window;
      Name : chars_ptr;
      Prot : aliased Atom := WM_Delete;
   begin
      Window := No_Window;
      for W in Valid_Window_Id loop
         if not Slots (W).Open then
            H := XCreateSimpleWindow
              (Display, XDefaultRootWindow (Display), 0, 0,
               unsigned (Size.Width), unsigned (Size.Height), 0,
               XBlackPixel (Display, Screen), XBlackPixel (Display, Screen));
            XSelectInput
              (Display, H,
               Key_Press_Mask + Key_Release_Mask + Button_Press_Mask
               + Button_Release_Mask + Pointer_Motion_Mask + Enter_Window_Mask
               + Leave_Window_Mask + Exposure_Mask + Structure_Notify_Mask
               + Focus_Change_Mask);
            if XSetWMProtocols (Display, H, Prot'Access, 1) = 0 then
               null;
            end if;
            Name := New_String (Title);
            XStoreName (Display, H, Name);
            Free (Name);
            if not Flags.Hidden then
               XMapWindow (Display, H);
            end if;
            XFlush (Display);
            Slots (W) := (Open => True, Handle => H, Size => Size,
                          others => <>);
            if not Cursor_Visible then
               XDefineCursor (Display, H, Create_Hidden_Cursor);
               XFlush (Display);
            end if;
            Window := W;
            return;
         end if;
      end loop;
   end Create_Window;

   procedure Destroy_Window (Window : Window_Id) is
   begin
      if Focus_Window = Window then
         Focus_Window := No_Window;
      end if;
      Release_Image (Window);
      if Slots (Window).Active_Cursor /= 0 then
         if XFreeCursor (Display, Slots (Window).Active_Cursor) = 0 then
            null;
         end if;
         Slots (Window).Active_Cursor := 0;
      end if;
      XDestroyWindow (Display, Slots (Window).Handle);
      XFlush (Display);
      Slots (Window).Open := False;
   end Destroy_Window;

   procedure Set_Title (Window : Window_Id; Title : String) is
      Name : chars_ptr := New_String (Title);
   begin
      XStoreName (Display, Slots (Window).Handle, Name);
      Free (Name);
      XFlush (Display);
   end Set_Title;

   procedure Set_Size (Window : Window_Id; Size : Bedrock.Screen.Size) is
   begin
      XResizeWindow (Display, Slots (Window).Handle,
                     unsigned (Size.Width), unsigned (Size.Height));
      XFlush (Display);
   end Set_Size;

   function Get_Size (Window : Window_Id) return Bedrock.Screen.Size is
   begin
      return Slots (Window).Size;
   end Get_Size;

   procedure Show (Window : Window_Id) is
   begin
      XMapWindow (Display, Slots (Window).Handle); XFlush (Display);
   end Show;

   procedure Hide (Window : Window_Id) is
   begin
      XUnmapWindow (Display, Slots (Window).Handle); XFlush (Display);
   end Hide;

   function Scale (Window : Window_Id) return Positive is
      pragma Unreferenced (Window);
      Settings : constant chars_ptr := XResourceManagerString (Display);
      DPI : Float := 0.0;
      Millimeters : int;
      Pixels_Wide : int;
      Result : Integer;
   begin
      if Settings /= Null_Ptr then
         declare
            Source : constant String := Value (Settings);
            Position : Natural := Ada.Strings.Fixed.Index (Source, "Xft.dpi:");
         begin
            if Position /= 0 then
               Position := Position + 8;
               declare
                  Last : Natural := Position;
               begin
                  while Last <= Source'Last and then Source (Last) /= ASCII.LF loop
                     Last := Last + 1;
                  end loop;
                  if Last > Position then
                     begin
                        DPI := Float'Value
                          (Ada.Strings.Fixed.Trim
                             (Source (Position .. Last - 1), Ada.Strings.Both));
                     exception
                        when Constraint_Error => DPI := 0.0;
                     end;
                  end if;
               end;
            end if;
         end;
      end if;

      if DPI <= 0.0 then
         Millimeters := XDisplayWidthMM (Display, Screen);
         Pixels_Wide := XDisplayWidth (Display, Screen);
         if Millimeters > 0 and then Pixels_Wide > 0 then
            DPI := Float (Pixels_Wide) * 25.4 / Float (Millimeters);
         end if;
      end if;

      if DPI < 48.0 or else DPI > 384.0 then
         return 100;
      end if;

      Result := Integer (DPI * 100.0 / 96.0);
      if Result < 50 then
         return 50;
      elsif Result > 400 then
         return 400;
      end if;
      return Positive (Result);
   end Scale;

   type Byte is mod 2 ** 8;
   type Byte_Array is array (Natural range <>) of Byte with Pack;
   type Byte_Array_Access is access Byte_Array;
   procedure Free_Bytes is new Ada.Unchecked_Deallocation
     (Byte_Array, Byte_Array_Access);

   --  Send the framebuffer to the X11 window.
   procedure Present (Window : Window_Id; Frame : Buffer) is
      W : constant Natural := Natural (Width (Frame));
      H : constant Natural := Natural (Height (Frame));
      Data : Byte_Array_Access;
      I    : Natural := 0;
   begin
      if W = 0 or else H = 0 then
         return;
      end if;

      --  The C X11 function expects four bytes per pixel (RGBA).
      Data := new Byte_Array (0 .. W * H * 4 - 1);
      for Y in 0 .. Frame.Height loop
         for X in 0 .. Frame.Width loop
            declare
               C : constant Color := Frame.Data (Y, X);
            begin
               Data (I)     := Byte (C.R);
               Data (I + 1) := Byte (C.G);
               Data (I + 2) := Byte (C.B);
               Data (I + 3) := Byte (C.A);
               I := I + 4;
            end;
         end loop;
      end loop;
      if Slots (Window).Image_Width /= W or else
         Slots (Window).Image_Height /= H
      then
         Release_Image (Window);
      end if;

      if Native_Present (Display, Slots (Window).Handle,
                         Graphics, Visual, Depth, Data.all'Address,
                         int (W), int (H), Slots (Window).Image'Access) /= 0
      then
         Slots (Window).Image_Width := W;
         Slots (Window).Image_Height := H;
      end if;
      Free_Bytes (Data);
   end Present;

   procedure Poll (E : out Event) is
   begin
      Pump;
      if Q_Count > 0 then
         E := Dequeue;
      else
         E := No_Event;
      end if;
   end Poll;

   procedure Wait (E : out Event; Timeout_Ms : Natural) is
      Deadline : constant Ticks := Now + Ticks (Timeout_Ms);
   begin
      loop
         Poll (E);
         exit when E.Kind /= None or else Now >= Deadline;
         Sleep (1);
      end loop;
   end Wait;

   procedure Push (E : Event) is
   begin
      Enqueue (E);
   end Push;

   function Is_Key_Down (K : Key) return Boolean is
   begin
      return Keys_Down (K);
   end Is_Key_Down;

   function Current_Modifiers return Modifiers is
   begin
      return Mods;
   end Current_Modifiers;

   function Mouse_Position (Window : Window_Id) return Point is
      Root, Child : aliased Xlib.Window;
      RX, RY, WX, WY : aliased int;
      Mask : aliased unsigned;
   begin
      if XQueryPointer (Display, Slots (Window).Handle, Root'Access, Child'Access,
                        RX'Access, RY'Access, WX'Access, WY'Access, Mask'Access) /= 0
      then
         return (Pixels (WX), Pixels (WY));
      end if;
      return (0, 0);
   end Mouse_Position;

   function Mouse_Buttons return Button_State is
   begin
      return Buttons;
   end Mouse_Buttons;

   function Gamepad (Id : Valid_Gamepad_Id) return Gamepad_State is
      pragma Unreferenced (Id);
   begin
      return (Connected => False, others => <>);
   end Gamepad;

   procedure Set_Text_Input (Window : Window_Id; Enabled : Boolean) is
   begin
      Text_Enabled (Window) := Enabled;
   end Set_Text_Input;

   procedure Set_Cursor (Window : Window_Id; Shape : Cursor_Shape) is
      New_Cursor : constant Xlib.Cursor := Create_Cursor (Shape);
      Old_Cursor : constant Xlib.Cursor := Slots (Window).Active_Cursor;
   begin
      Slots (Window).Active_Cursor := New_Cursor;
      if Cursor_Visible then
         if New_Cursor /= 0 then
            XDefineCursor (Display, Slots (Window).Handle, New_Cursor);
         else
            XUndefineCursor (Display, Slots (Window).Handle);
         end if;
      end if;
      if Old_Cursor /= 0 then
         if XFreeCursor (Display, Old_Cursor) = 0 then
            null;
         end if;
      end if;
      XFlush (Display);
   end Set_Cursor;

   procedure Set_Cursor_Visible (Visible : Boolean) is
      Hidden : Xlib.Cursor := 0;
   begin
      Cursor_Visible := Visible;
      if not Visible then
         Hidden := Create_Hidden_Cursor;
      end if;
      for W in Valid_Window_Id loop
         if Slots (W).Open then
            if not Visible and then Hidden /= 0 then
               XDefineCursor (Display, Slots (W).Handle, Hidden);
            elsif Slots (W).Active_Cursor /= 0 then
               XDefineCursor (Display, Slots (W).Handle,
                              Slots (W).Active_Cursor);
            else
               XUndefineCursor (Display, Slots (W).Handle);
            end if;
         end if;
      end loop;
      XFlush (Display);
   end Set_Cursor_Visible;

   --  Read the system clipboard.
   procedure Get_Clipboard (Text : out String; Last : out Natural) is
      type Clipboard_Bytes is array (Natural range 0 .. Max_Clipboard - 1)
        of unsigned_char with Convention => C;
      Data : aliased Clipboard_Bytes := [others => 0];
      Received : constant int := Native_Clipboard_Get
        (Data'Address, int (Text'Length));
      N : constant Natural :=
        (if Received > 0 then Natural'Min (Natural (Received), Text'Length)
         else 0);
   begin
      if N > 0 then
         for I in 0 .. N - 1 loop
            Text (Text'First + I) := Character'Val (Natural (Data (I)));
         end loop;
      end if;
      Last := Text'First + N - 1;
   end Get_Clipboard;

   procedure Set_Clipboard (Text : String) is
   begin
      Native_Clipboard_Set
        ((if Text'Length > 0 then Text'Address else System.Null_Address),
         int (Text'Length));
   end Set_Clipboard;

   function Now return Ticks is
      use Ada.Calendar;
   begin
      if not Initialized then
         return 0;
      end if;
      return Ticks (Duration'(Clock - Start) * 1000.0);
   end Now;

   procedure Sleep (Ms : Natural) is
   begin
      delay Duration (Ms) / 1000.0;
   end Sleep;

end Portal.Backend;
