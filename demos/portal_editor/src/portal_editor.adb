with Ada.Text_IO; use Ada.Text_IO;
with Ada.Unchecked_Deallocation;
with Bedrock.Screen; use Bedrock.Screen;
with Bedrock.Colors; use Bedrock.Colors;
with Portal.Backend; use Portal.Backend;
with Portal.Framebuffer; use Portal.Framebuffer;
with Portal.Input; use Portal.Input;

procedure Portal_Editor is
   Cols : constant := 80;
   Rows : constant := 60;
   Top  : constant := 64;

   type Color_Index is range 0 .. 6;
   type Canvas_Type is array (Natural range 0 .. Rows - 1,
                              Natural range 0 .. Cols - 1) of Color_Index;

   Canvas : Canvas_Type := [others => [others => 0]];

   Palette : constant array (Color_Index range 0 .. 6) of Color :=
     [0 => (248, 249, 251, 255),
      1 => (229, 80, 84, 255),
      2 => (243, 168, 65, 255),
      3 => (242, 219, 90, 255),
      4 => (78, 184, 122, 255),
      5 => (64, 139, 224, 255),
      6 => (167, 99, 206, 255)];

   Codes : constant array (Color_Index range 1 .. 6) of String (1 .. 7) :=
     ["#E55054", "#F3A841", "#F2DB5A", "#4EB87A", "#408BE0", "#A763CE"];

   type Frame_Access is access Buffer;
   procedure Free_Frame is new Ada.Unchecked_Deallocation (Buffer, Frame_Access);

   Win            : Window_Id;
   Started        : Boolean;
   E              : Event;
   Frame          : Frame_Access := null;
   Frame_W        : Natural := 800;
   Frame_H        : Natural := 600;
   Selected       : Color_Index := 1;
   Zoom           : Natural range 8 .. 32 := 16;
   Erasing        : Boolean := False;
   Painting       : Boolean := False;
   Current_Cursor : Cursor_Shape := Arrow;
   Mouse          : Point := (0, 0);
   Running        : Boolean := True;

   procedure Resize_Frame (S : Bedrock.Screen.Size);
   function Is_Canvas_Point (P : Point) return Boolean;
   procedure Paint (P : Point);
   procedure Hover_Cursor (P : Point);
   procedure Click (P : Point);
   procedure Draw;
   procedure Copy_Color;
   procedure Paste_Color;

   procedure Resize_Frame (S : Bedrock.Screen.Size) is
      W : Natural := Natural (S.Width);
      H : Natural := Natural (S.Height);
   begin
      if W = 0 then
         W := 1;
      elsif W > Natural (Max_Width) then
         W := Natural (Max_Width);
      end if;

      if H = 0 then
         H := 1;
      elsif H > Natural (Max_Height) then
         H := Natural (Max_Height);
      end if;

      if Frame = null or else W /= Frame_W or else H /= Frame_H then
         Free_Frame (Frame);
         Frame := new Buffer (Row (H - 1), Column (W - 1));
         Frame_W := W;
         Frame_H := H;
      end if;
   end Resize_Frame;

   function Is_Canvas_Point (P : Point) return Boolean is
   begin
      return Integer (P.X) >= 12
        and then Integer (P.Y) >= Top
        and then Integer (P.X) < Integer (Frame_W) - 12
        and then Integer (P.Y) < Integer (Frame_H) - 24;
   end Is_Canvas_Point;

   procedure Paint (P : Point) is
      X : Natural;
      Y : Natural;
   begin
      if not Is_Canvas_Point (P) then
         return;
      end if;

      X := Natural ((Integer (P.X) - 12) / Integer (Zoom));
      Y := Natural ((Integer (P.Y) - Top) / Integer (Zoom));

      if X < Cols and then Y < Rows then
         if Erasing then
            Canvas (Y, X) := 0;
         else
            Canvas (Y, X) := Selected;
         end if;
      end if;
   end Paint;

   procedure Hover_Cursor (P : Point) is
      New_Cursor : Cursor_Shape := Arrow;
   begin
      if Integer (P.Y) < Top then
         New_Cursor := Hand;
      elsif Is_Canvas_Point (P) then
         New_Cursor := Crosshair;
      end if;

      if New_Cursor /= Current_Cursor then
         Set_Cursor (Win, New_Cursor);
         Current_Cursor := New_Cursor;
      end if;
   end Hover_Cursor;

   procedure Click (P : Point) is
      X : constant Integer := Integer (P.X);
      Y : constant Integer := Integer (P.Y);
   begin
      if Y >= 8 and then Y < 48 and then X >= 12 and then X < 300 then
         Selected := Color_Index ((X - 12) / 48 + 1);
         Erasing := False;
      else
         Paint (P);
      end if;
   end Click;

   procedure Draw is
      Preview    : Buffer (15, 15);
      Max_X      : Natural;
      Max_Y      : Natural;
      X_Px       : Integer;
      Y_Px       : Integer;
      Mouse_X    : Natural;
      Mouse_Y    : Natural;
   begin
      Clear (Frame.all, (30, 34, 43, 255));

      if Frame_W <= 24 or else Frame_H <= Top + 24 then
         Present (Win, Frame.all);
         return;
      end if;

      Fill (Frame.all,
            ((12, Top), (Extent (Frame_W - 24), Extent (Frame_H - Top - 24))),
            (205, 209, 215, 255));

      for I in Color_Index range 1 .. 6 loop
         X_Px := 12 + (Integer (I) - 1) * 48;

         if I = Selected then
            Fill (Frame.all, ((Pixels (X_Px - 2), 6), (44, 44)),
                  (255, 255, 255, 255));
         end if;

         Fill (Frame.all, ((Pixels (X_Px), 8), (40, 40)), Palette (I));
      end loop;

      Clear (Preview, Palette (Selected));

      if Frame_W >= 42 then
         Blit (Frame.all, Preview, (Pixels (Frame_W - 42), 16));
      end if;

      Max_X := Natural'Min (Cols - 1, (Frame_W - 24) / Zoom);
      Max_Y := Natural'Min (Rows - 1, (Frame_H - Top - 24) / Zoom);

      for Y in 0 .. Max_Y loop
         for X in 0 .. Max_X loop
            X_Px := 12 + X * Zoom;
            Y_Px := Top + Y * Zoom;

            Fill (Frame.all,
                  ((Pixels (X_Px), Pixels (Y_Px)),
                   (Extent (Zoom - 1), Extent (Zoom - 1))),
                  Palette (Canvas (Y, X)));
         end loop;
      end loop;

      if Is_Canvas_Point (Mouse) then
         Mouse_X := Natural ((Integer (Mouse.X) - 12) / Integer (Zoom));
         Mouse_Y := Natural ((Integer (Mouse.Y) - Top) / Integer (Zoom));

         if Mouse_X < Cols and then Mouse_Y < Rows then
            Fill_Blend (Frame.all,
                        ((Pixels (12 + Mouse_X * Zoom),
                          Pixels (Top + Mouse_Y * Zoom)),
                         (Extent (Zoom), Extent (Zoom))),
                        (255, 255, 255, 100));
         end if;
      end if;

      Present (Win, Frame.all);
   end Draw;

   procedure Copy_Color is
   begin
      Set_Clipboard (Codes (Selected));
      Put_Line ("Copied color " & Codes (Selected));
   end Copy_Color;

   procedure Paste_Color is
      Data : String (1 .. 64);
      Last : Natural;
   begin
      Get_Clipboard (Data, Last);

      if Last >= Data'First then
         for I in Codes'Range loop
            if Last = 7 and then Data (1 .. 7) = Codes (I) then
               Selected := I;
               Erasing := False;
               Put_Line ("Pasted color " & Codes (I));
               return;
            end if;
         end loop;

         Put_Line ("Clipboard: " & Data (Data'First .. Last));
      end if;
   end Paste_Color;

begin
   Initialize (Started);
   if not Started then
      Put_Line ("Portal initialization failed");
      return;
   end if;

   Create_Window ("Portal Pixel Editor", (800, 600), (others => <>), Win);
   if Win = No_Window then
      Put_Line ("Window creation failed");
      Finalize;
      return;
   end if;

   Resize_Frame (Get_Size (Win));
   Set_Cursor (Win, Arrow);

   Put_Line ("Left click/drag paint, palette at top, wheel zoom, E erase, R reset");
   Put_Line ("C copy hex color, V paste hex color");
   Put_Line ("Esc closes the editor. Same application on X11 and Win32.");

   while Running loop
      loop
         Poll (E);
         exit when E.Kind = None;

         case E.Kind is
            when Quit | Window_Close =>
               Running := False;

            when Window_Resized =>
               Resize_Frame (E.Size);

            when Mouse_Move =>
               Mouse := E.At_Pos;
               if Painting then
                  Paint (Mouse);
               end if;
               Hover_Cursor (Mouse);

            when Mouse_Down =>
               if E.Button = Left then
                  Mouse := E.Where;
                  Painting := True;
                  Click (Mouse);
               end if;

            when Mouse_Up =>
               if E.Button = Left then
                  Painting := False;
               end if;

            when Mouse_Wheel =>
               if E.Wheel_Y > 0 then
                  Zoom := Natural'Min (32, Zoom + 2);
               elsif E.Wheel_Y < 0 then
                  Zoom := Natural'Max (8, Zoom - 2);
               end if;

            when Key_Down =>
               case E.Key is
                  when Key_Escape => Running := False;
                  when Key_C => Copy_Color;
                  when Key_V => Paste_Color;
                  when Key_E => Erasing := not Erasing;
                  when Key_R => Canvas := [others => [others => 0]];
                  when others => null;
               end case;

            when others =>
               null;
         end case;
      end loop;

      exit when not Running;
      Draw;
      Sleep (16);
   end loop;

   Free_Frame (Frame);
   Destroy_Window (Win);
   Finalize;
end Portal_Editor;
